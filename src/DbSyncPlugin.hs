{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module DbSyncPlugin
  ( poolMetadataDbSyncNodePlugin
  ) where

import           Cardano.Prelude

import           Cardano.BM.Trace                            (Trace, logError,
                                                              logInfo)

import           Control.Monad.Logger                        (LoggingT)
import           Control.Monad.Trans.Except.Extra (firstExceptT, newExceptT, runExceptT)
import           Control.Monad.Trans.Reader                  (ReaderT)

import           DB                                          (DBFail (..),
                                                              DataLayer (..),
                                                              postgresqlDataLayer)
import           Offline (fetchInsertNewPoolMetadata)
import           Types                                       (PoolId (..), PoolMetadataHash (..),
                                                              PoolUrl (..))

import qualified Cardano.Chain.Block as Byron

import qualified Data.ByteString.Base16                      as B16

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
    mapM_ (insertCertificate tracer) (Shelley.txCertificates tx)


insertCertificate
    :: (MonadIO m)
    => Trace IO Text -> (Word16, ShelleyDCert)
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertCertificate tracer (_idx, cert) =
  case cert of
    Shelley.DCertDeleg _deleg ->
        liftIO $ logInfo tracer "insertCertificate: DCertDeleg"
    Shelley.DCertPool pool -> insertPoolCert tracer pool
    Shelley.DCertMir _mir ->
        liftIO $ logInfo tracer "insertCertificate: DCertMir"
    Shelley.DCertGenesis _gen ->
        liftIO $ logError tracer "insertCertificate: Unhandled DCertGenesis certificate"

insertPoolCert
    :: (MonadIO m)
    => Trace IO Text -> ShelleyPoolCert
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertPoolCert tracer pCert =
  case pCert of
    Shelley.RegPool pParams -> insertPoolRegister tracer pParams
    Shelley.RetirePool _keyHash _epochNum -> pure ()
        -- Currently we just maintain the data for the pool, we might not want to
        -- know whether it's registered

insertPoolRegister
    :: forall m. (MonadIO m)
    => Trace IO Text
    -> ShelleyPoolParams
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertPoolRegister tracer params = do
  let poolIdHash = B16.encode . Shelley.unKeyHashBS $ Shelley._poolPubKey params
  let poolId = PoolId . decodeUtf8 $ poolIdHash

  liftIO . logInfo tracer $ "Inserting pool register with pool id: " <> decodeUtf8 poolIdHash
  case strictMaybeToMaybe $ Shelley._poolMD params of
    Just md -> do

        liftIO . logInfo tracer $ "Inserting metadata."
        let metadataUrl = PoolUrl . Shelley.urlToText $ Shelley._poolMDUrl md
        let metadataHash = PoolMetadataHash . decodeUtf8 . B16.encode $ Shelley._poolMDHash md

        -- Ah. We can see there is garbage all over the code. Needs refactoring.
        refId <- lift . liftIO $ (dlAddMetaDataReference postgresqlDataLayer) poolId metadataUrl metadataHash

        liftIO $ fetchInsertNewPoolMetadata postgresqlDataLayer tracer refId poolId md

        liftIO . logInfo tracer $ "Metadata inserted."

    Nothing -> pure ()

  liftIO . logInfo tracer $ "Inserted pool register."
  pure ()
