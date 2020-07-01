module DbSyncPlugin
  ( poolMetadataDbSyncNodePlugin
  ) where

import           Cardano.Prelude

import           Cardano.BM.Trace (Trace, logInfo)

import           Control.Monad.Logger (LoggingT)
import           Control.Monad.Trans.Reader (ReaderT)

import           Database.Persist.Sql (SqlBackend)

import qualified Cardano.Db.Schema as DB
import           Cardano.Db.Insert (insertPoolMetaData)
import           Cardano.Db.Run

import           Cardano.DbSync.Error
--import qualified Cardano.DbSync.Plugin.Default.Byron.Insert as Byron
--import qualified Cardano.DbSync.Plugin.Default.Shelley.Insert as Shelley
import           Cardano.DbSync.Types

import           Cardano.DbSync (DbSyncNodePlugin (..), defDbSyncNodePlugin)
import           Cardano.DbSync.Plugin.Epoch (epochPluginOnStartup, epochPluginInsertBlock,
                    epochPluginRollbackBlock)

import           Ouroboros.Consensus.Byron.Ledger (ByronBlock (..))

import qualified Cardano.DbSync.Era.Byron.Util as Byron
import qualified Cardano.DbSync.Era.Shelley.Util as Shelley

import qualified Shelley.Spec.Ledger.Address as Shelley
import           Shelley.Spec.Ledger.BaseTypes (strictMaybeToMaybe)
import qualified Shelley.Spec.Ledger.BaseTypes as Shelley
import qualified Shelley.Spec.Ledger.Coin as Shelley
import qualified Shelley.Spec.Ledger.Tx as Shelley
import qualified Shelley.Spec.Ledger.TxData as Shelley


poolMetadataDbSyncNodePlugin :: DbSyncNodePlugin
poolMetadataDbSyncNodePlugin =
  defDbSyncNodePlugin
    { plugOnStartup = []
        --plugOnStartup defDbSyncNodePlugin ++ [epochPluginOnStartup] ++ []

    , plugInsertBlock = [insertCardanoBlock]
        --plugInsertBlock defDbSyncNodePlugin ++ [epochPluginInsertBlock] ++ [insertCardanoBlock]

    , plugRollbackBlock = []
        --plugRollbackBlock defDbSyncNodePlugin ++ [epochPluginRollbackBlock] ++ []
    }

insertCardanoBlock
    :: Trace IO Text -> DbSyncEnv -> CardanoBlockTip
    -> ReaderT SqlBackend (LoggingT IO) (Either DbSyncNodeError ())
insertCardanoBlock tracer _env blkTip = do
  case blkTip of
    ByronBlockTip blk tip -> pure $ Right ()  --insertByronBlock tracer blk tip
    ShelleyBlockTip blk tip -> insertShelleyBlock tracer blk tip

-- We don't care about Byron, no pools there
--insertByronBlock
--    :: Trace IO Text -> ByronBlock -> Tip ByronBlock
--    -> ReaderT SqlBackend (LoggingT IO) (Either DbSyncNodeError ())
--insertByronBlock tracer blk tip = do
--  runExceptT $
--    liftIO $ do
--      let epoch = Byron.slotNumber blk `div` 5000
--      logInfo tracer $ mconcat
--        [ "insertByronBlock: epoch ", show epoch
--        , ", slot ", show (Byron.slotNumber blk)
--        , ", block ", show (Byron.blockNumber blk)
--        ]

insertShelleyBlock
    :: Trace IO Text -> ShelleyBlock -> Tip ShelleyBlock
    -> ReaderT SqlBackend (LoggingT IO) (Either DbSyncNodeError ())
insertShelleyBlock tracer blk tip = do
  runExceptT $ do
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
insertTx tracer blockIndex tx =
    mapM_ (insertPoolCert tracer) (Shelley.txPoolCertificates $ Shelley._body tx)

insertPoolCert
    :: (MonadIO m)
    => Trace IO Text -> ShelleyPoolCert
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertPoolCert tracer pCert =
  case pCert of
    Shelley.RegPool pParams -> void $ insertPoolRegister tracer pParams
    Shelley.RetirePool keyHash epochNum -> pure ()
        -- Currently we just maintain the data for the pool, we might not want to
        -- know whether it's registered

insertPoolRegister
    :: (MonadIO m)
    => Trace IO Text -> ShelleyPoolParams
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) (Maybe DB.PoolMetaDataId)
insertPoolRegister tracer params = do
  liftIO . logInfo tracer $ "Inserting pool register."
  poolMetadataId <- case strictMaybeToMaybe $ Shelley._poolMD params of
    Just md -> do
        -- Fetch the JSON info!
        liftIO . logInfo tracer $ "Fetching JSON metadata."
        liftIO . logInfo tracer $ "Inserting JSON offline metadata."
        liftIO . logInfo tracer $ "Inserting metadata."
        Just <$> insertMetaData tracer md
    Nothing -> pure Nothing
  liftIO . logInfo tracer $ "Inserted pool register."
  return poolMetadataId

insertMetaData
    :: (MonadIO m)
    => Trace IO Text -> Shelley.PoolMetaData
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) DB.PoolMetaDataId
insertMetaData _tracer md =
  lift . insertPoolMetaData $
    DB.PoolMetaData
      { DB.poolMetaDataUrl = Shelley.urlToText (Shelley._poolMDUrl md)
      , DB.poolMetaDataHash = Shelley._poolMDHash md
      }

--insertPoolRetire
--    :: (MonadIO m)
--    => EpochNo -> ShelleyStakePoolKeyHash
--    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
--insertPoolRetire epochNum keyHash = do
--  poolId <- firstExceptT (NELookup "insertPoolRetire") . newExceptT $ queryStakePoolKeyHash keyHash
--  void . lift . DB.insertPoolRetire $
--    DB.PoolRetire
--      { DB.poolRetirePoolId = poolId
--      , DB.poolRetireRetiringEpoch = unEpochNo epochNum
--      }



