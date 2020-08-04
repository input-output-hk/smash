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
                                                              postgresqlDataLayer,
                                                              runDbAction)
import           Types                                       (PoolId (..), PoolMetadataHash (..),
                                                              PoolMetadataRaw (..),
                                                              PoolOfflineMetadata (..),
                                                              PoolUrl (..))

import           Data.Aeson                                  (eitherDecode')
import qualified Data.ByteString.Lazy                        as BL

import qualified Cardano.Crypto.Hash.Blake2b                 as Crypto
import qualified Cardano.Crypto.Hash.Class                   as Crypto

import qualified Data.ByteString.Base16                      as B16

import           Network.HTTP.Client (HttpExceptionContent (..), HttpException (..), Request, Response)
import qualified Network.HTTP.Client as Http
import           Network.HTTP.Client.TLS (tlsManagerSettings)
import           Network.HTTP.Types.Status (statusCode)

import           Database.Persist.Sql                        (SqlBackend)

import qualified Cardano.Db.Insert                           as DB
import qualified Cardano.Db.Query                            as DB
import qualified Cardano.Db.Schema                           as DB

import           Cardano.DbSync.Error
import           Cardano.DbSync.Types                        as DbSync

import           Cardano.DbSync                              (DbSyncNodePlugin (..))

import qualified Cardano.DbSync.Era.Shelley.Util             as Shelley

import           Shelley.Spec.Ledger.BaseTypes               (strictMaybeToMaybe)
import qualified Shelley.Spec.Ledger.BaseTypes               as Shelley
import qualified Shelley.Spec.Ledger.TxData                  as Shelley

import           Ouroboros.Consensus.Shelley.Ledger          (ShelleyBlock)
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
insertCardanoBlock _tracer _env ByronBlockDetails{} =
    pure $ Right ()  -- we do nothing for Byron era blocks
insertCardanoBlock tracer _env (ShelleyBlockDetails blk _) =
    insertShelleyBlock tracer blk

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
      let epoch = Shelley.slotNumber blk `div` 5000
      logInfo tracer $ mconcat
        [ "insertShelleyBlock pool info: epoch ", show epoch
        , ", slot ", show (Shelley.slotNumber blk)
        , ", block ", show (Shelley.blockNumber blk)
        ]

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

        let eitherPoolMetadata :: IO (Either DbSyncNodeError (Response BL.ByteString))
            eitherPoolMetadata = runExceptT (fetchInsertPoolMetadata tracer poolId md)

        liftIO $ eitherPoolMetadata >>= \case
                Left err -> logError tracer $ renderDbSyncNodeError err
                Right response -> logInfo tracer (decodeUtf8 . BL.toStrict $ Http.responseBody response)

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

fetchInsertPoolMetadata
    :: Trace IO Text
    -> PoolId
    -> Shelley.PoolMetaData
    -> ExceptT DbSyncNodeError IO (Response BL.ByteString)
fetchInsertPoolMetadata tracer poolId md = do
    -- Fetch the JSON info!
    liftIO . logInfo tracer $ "Fetching JSON metadata."

    let poolUrl = Shelley.urlToText (Shelley._poolMDUrl md)

    -- This is a bit bad to do each time, but good enough for now.
    manager <- liftIO $ Http.newManager tlsManagerSettings

    liftIO . logInfo tracer $ "Request created with URL '" <> poolUrl <> "'."

    let exceptRequest :: ExceptT DbSyncNodeError IO Request
        exceptRequest = handleExceptT (\(e :: HttpException) -> NEError $ show e) (Http.parseRequest $ toS poolUrl)

    request <- exceptRequest

    liftIO . logInfo tracer $ "HTTP Client GET request."

    -- The response size check.
    _responseRaw <- handleExceptT (\(e :: HttpException) -> NEError $ show e) $ Http.withResponse request manager $ \responseBR -> do
        -- We read the first chunk that should contain all the bytes from the reponse.
        responseBSFirstChunk <- Http.brReadSome (Http.responseBody responseBR) 512
        -- If there are more bytes in the second chunk, we don't go any further since that
        -- violates the size constraint.
        responseBSSecondChunk <- Http.brReadSome (Http.responseBody responseBR) 512
        if BL.null responseBSSecondChunk
           then pure responseBSFirstChunk
           else throwIO $ HttpExceptionRequest request NoResponseDataReceived

    -- The request for fetching the full content strictly.
    let httpRequest :: MonadIO n => n (Response BL.ByteString)
        httpRequest = liftIO $ Http.httpLbs request manager

    response <- handleExceptT (\(e :: HttpException) -> NEError $ show e) httpRequest

    liftIO . logInfo tracer $ "HTTP GET request complete."
    liftIO . logInfo tracer $ "The status code was: " <> (show $ statusCode $ Http.responseStatus response)

    let poolMetadataJson = decodeUtf8 . BL.toStrict $ Http.responseBody response

    let mdHash :: ByteString
        mdHash = Shelley._poolMDHash md

    let poolHash :: Text
        poolHash = decodeUtf8 . B16.encode $ mdHash

    liftIO . logInfo tracer $ "Inserting pool with hash: " <> poolHash

    -- Pass this in, not create it here.
    let dataLayer :: DataLayer
        dataLayer = postgresqlDataLayer

    -- Let us try to decode the contents to JSON.
    let decodedPoolMetadataJSON :: Either DBFail PoolOfflineMetadata
        decodedPoolMetadataJSON = case (eitherDecode' (Http.responseBody response)) of
            Left err -> Left $ UnableToEncodePoolMetadataToJSON $ toS err
            Right result -> return result

    decodedMetadata <- firstExceptT (\e -> NEError $ show e) (newExceptT $ pure decodedPoolMetadataJSON)

    -- Let's check the hash
    let poolHashBytestring = encodeUtf8 poolHash
    let poolMetadataBytestring = encodeUtf8 poolMetadataJson
    let hashFromMetadata = B16.encode $ Crypto.digest (Proxy :: Proxy Crypto.Blake2b_256) poolMetadataBytestring

    when (hashFromMetadata /= poolHashBytestring) $
        left . NEError $ "The pool hash does not match: " <> poolHash

    liftIO . logInfo tracer $ "Inserting JSON offline metadata."

    let addPoolMetadata = dlAddPoolMetadata dataLayer
    _ <- liftIO $ addPoolMetadata
        poolId
        (PoolMetadataHash poolHashBytestring)
        poolMetadataJson
        (pomTicker decodedMetadata)

    pure response

