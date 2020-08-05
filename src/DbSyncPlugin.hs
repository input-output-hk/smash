{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module DbSyncPlugin
  ( poolMetadataDbSyncNodePlugin
  ) where

import           Cardano.Prelude

import           Cardano.BM.Trace                            (Trace, logError,
                                                              logInfo)

import           Control.Monad.Logger                        (LoggingT)
import           Control.Monad.Trans.Except.Extra            (firstExceptT,
                                                              handleExceptT,
                                                              left, newExceptT,
                                                              runExceptT)
import           Control.Monad.Trans.Reader                  (ReaderT)

import           DB                                          (DBFail (..),
                                                              DataLayer (..),
                                                              postgresqlDataLayer)
import           Types                                       (PoolId (..), PoolMetadataHash (..),
                                                              PoolOfflineMetadata (..),
                                                              PoolUrl (..))

import           Data.Aeson (eitherDecode')
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text.Encoding as Text

import qualified Cardano.Chain.Block as Byron

import qualified Cardano.Crypto.Hash.Class as Crypto
import qualified Cardano.Crypto.Hash.Blake2b as Crypto

import qualified Data.ByteString.Base16                      as B16

import           Network.HTTP.Client (HttpExceptionContent (..), HttpException (..))
import qualified Network.HTTP.Client as Http
import           Network.HTTP.Client.TLS (tlsManagerSettings)
import qualified Network.HTTP.Types.Status as Http

import           Database.Persist.Sql (IsolationLevel (..), SqlBackend, transactionSaveWithIsolation)

import qualified Cardano.Db.Insert                           as DB
import qualified Cardano.Db.Query                            as DB
import qualified Cardano.Db.Schema                           as DB

import           Cardano.DbSync.Error
import           Cardano.DbSync.Types                        as DbSync

import           Cardano.DbSync                              (DbSyncNodePlugin (..))

import qualified Cardano.DbSync.Era.Shelley.Util             as Shelley

import           Shelley.Spec.Ledger.BaseTypes (strictMaybeToMaybe)
import qualified Shelley.Spec.Ledger.BaseTypes as Shelley
import qualified Shelley.Spec.Ledger.TxData as Shelley

import           Ouroboros.Consensus.Byron.Ledger (ByronBlock (..))
import           Ouroboros.Consensus.Shelley.Ledger.Block (ShelleyBlock)
import           Ouroboros.Consensus.Shelley.Protocol.Crypto (TPraosStandardCrypto)

poolMetadataDbSyncNodePlugin :: DbSyncNodePlugin
poolMetadataDbSyncNodePlugin =
  DbSyncNodePlugin
    { plugOnStartup = []
    , plugInsertBlock = [insertCardanoBlock]
    , plugRollbackBlock = []
    }

insertCardanoBlock
    :: Trace IO Text
    -> DbSyncEnv
    -> DbSync.BlockDetails
    -> ReaderT SqlBackend (LoggingT IO) (Either DbSyncNodeError ())
insertCardanoBlock tracer _env block = do
  case block of
    ByronBlockDetails blk _details -> Right <$> insertByronBlock tracer blk
    ShelleyBlockDetails blk _details -> insertShelleyBlock tracer blk

-- We don't care about Byron, no pools there
insertByronBlock
    :: Trace IO Text -> ByronBlock
    -> ReaderT SqlBackend (LoggingT IO) ()
insertByronBlock tracer blk = do
  case byronBlockRaw blk of
    Byron.ABOBBlock {} -> pure ()
    Byron.ABOBBoundary {} -> liftIO $ logInfo tracer "Byron EBB"
  transactionSaveWithIsolation Serializable

insertShelleyBlock
    :: Trace IO Text
    -> ShelleyBlock TPraosStandardCrypto
    -> ReaderT SqlBackend (LoggingT IO) (Either DbSyncNodeError ())
insertShelleyBlock tracer blk = do
  runExceptT $ do

    meta <- firstExceptT (\(e :: DBFail) -> NEError $ show e) . newExceptT $ DB.queryMeta

    let slotsPerEpoch = DB.metaSlotsPerEpoch meta

    _blkId <- lift . DB.insertBlock $
                  DB.Block
                    { DB.blockHash = Shelley.blockHash blk
                    , DB.blockEpochNo = Just $ Shelley.slotNumber blk `div` slotsPerEpoch
                    , DB.blockSlotNo = Just $ Shelley.slotNumber blk
                    , DB.blockBlockNo = Just $ Shelley.blockNumber blk
                    }

    zipWithM_ (insertTx tracer) [0 .. ] (Shelley.blockTxs blk)

    liftIO $ do
      logInfo tracer $ mconcat
        [ "insertShelleyBlock pool info: slot ", show (Shelley.slotNumber blk)
        , ", block ", show (Shelley.blockNumber blk)
        ]
    lift $ transactionSaveWithIsolation Serializable

insertTx
    :: (MonadIO m)
    => Trace IO Text -> Word64 -> ShelleyTx
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertTx tracer _blockIndex tx =
    mapM_ (insertPoolCert tracer) (Shelley.txPoolCertificates tx)

insertPoolCert
    :: (MonadIO m)
    => Trace IO Text -> ShelleyPoolCert
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertPoolCert tracer pCert =
  case pCert of
    Shelley.RegPool pParams -> void $ insertPoolRegister tracer pParams
    Shelley.RetirePool _keyHash _epochNum -> pure ()
        -- Currently we just maintain the data for the pool, we might not want to
        -- know whether it's registered

insertPoolRegister
    :: forall m. (MonadIO m)
    => Trace IO Text
    -> ShelleyPoolParams
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) (Maybe DB.PoolMetadataReferenceId)
insertPoolRegister tracer params = do
  let poolIdHash = B16.encode . Shelley.unKeyHashBS $ Shelley._poolPubKey params
  let poolId = PoolId poolIdHash


  liftIO . logInfo tracer $ "Inserting pool register with pool id: " <> decodeUtf8 poolIdHash
  poolMetadataId <- case strictMaybeToMaybe $ Shelley._poolMD params of
    Just md -> do

        liftIO $ fetchInsertPoolMetadataWrap tracer poolId md

        liftIO . logInfo tracer $ "Inserting metadata."
        let metadataUrl = PoolUrl . Shelley.urlToText $ Shelley._poolMDUrl md
        let metadataHash = PoolMetadataHash . B16.encode $ Shelley._poolMDHash md

        -- Move this upward, this doesn't make sense here. Kills any testing efforts here.
        let dataLayer :: DataLayer
            dataLayer = postgresqlDataLayer

        let addMetaDataReference = dlAddMetaDataReference dataLayer

        -- Ah. We can see there is garbage all over the code. Needs refactoring.
        pmId <- lift . liftIO $ rightToMaybe <$> addMetaDataReference poolId metadataUrl metadataHash

        liftIO . logInfo tracer $ "Metadata inserted."

        return pmId

    Nothing -> pure Nothing

  liftIO . logInfo tracer $ "Inserted pool register."
  return poolMetadataId

fetchInsertPoolMetadataWrap
    :: Trace IO Text
    -> PoolId
    -> Shelley.PoolMetaData
    -> IO ()
fetchInsertPoolMetadataWrap tracer poolId md = do
    res <- runExceptT $ fetchInsertPoolMetadata tracer poolId md
    case res of
        Left err -> logError tracer $ renderDbSyncNodeError err
        Right response -> logInfo tracer (decodeUtf8 response)


fetchInsertPoolMetadata
    :: Trace IO Text
    -> PoolId
    -> Shelley.PoolMetaData
    -> ExceptT DbSyncNodeError IO ByteString
fetchInsertPoolMetadata tracer poolId md = do
    -- Fetch the JSON info!
    liftIO . logInfo tracer $ "Fetching JSON metadata."

    let poolUrl = Shelley.urlToText (Shelley._poolMDUrl md)

    -- This is a bit bad to do each time, but good enough for now.
    manager <- liftIO $ Http.newManager tlsManagerSettings

    liftIO . logInfo tracer $ "Request created with URL '" <> poolUrl <> "'."

    request <- handleExceptT (\(e :: HttpException) -> NEError $ show e) (Http.parseRequest $ toS poolUrl)

    liftIO . logInfo tracer $ "HTTP Client GET request."

    (respBS, status) <- liftIO $ httpGetMax512Bytes request manager

    liftIO . logInfo tracer $ "HTTP GET request response: " <> show status

    liftIO . logInfo tracer $ "Inserting pool with hash: " <> renderByteStringHex (Shelley._poolMDHash md)

    -- Let us try to decode the contents to JSON.
    decodedMetadata <- case eitherDecode' (LBS.fromStrict respBS) of
                        Left err -> left $ NEError (show $ UnableToEncodePoolMetadataToJSON (toS err))
                        Right result -> pure result

    -- Let's check the hash
    let hashFromMetadata = Crypto.digest (Proxy :: Proxy Crypto.Blake2b_256) respBS

    when (hashFromMetadata /= Shelley._poolMDHash md) $
        left . NEError $
          mconcat
            [ "Pool hash mismatch. Expected ", renderByteStringHex (Shelley._poolMDHash md)
            , " but got ", renderByteStringHex hashFromMetadata
            ]

    liftIO . logInfo tracer $ "Inserting JSON offline metadata."

    let addPoolMetadata = dlAddPoolMetadata postgresqlDataLayer
    _ <- liftIO $ addPoolMetadata
        poolId
        (PoolMetadataHash . B16.encode $ Shelley._poolMDHash md)
        (decodeUtf8 respBS)
        (pomTicker decodedMetadata)

    pure respBS


httpGetMax512Bytes :: Http.Request -> Http.Manager -> IO (ByteString, Http.Status)
httpGetMax512Bytes request manager =
    Http.withResponse request manager $ \responseBR -> do
        -- We read the first chunk that should contain all the bytes from the reponse.
        responseBSFirstChunk <- Http.brReadSome (Http.responseBody responseBR) 512
        -- If there are more bytes in the second chunk, we don't go any further since that
        -- violates the size constraint.
        responseBSSecondChunk <- Http.brReadSome (Http.responseBody responseBR) 1
        if LBS.null responseBSSecondChunk
           then pure $ (LBS.toStrict responseBSFirstChunk, Http.responseStatus responseBR)
           -- TODO: this is just WRONG.
           else throwIO $ HttpExceptionRequest request NoResponseDataReceived

renderByteStringHex :: ByteString -> Text
renderByteStringHex = Text.decodeUtf8 . B16.encode
