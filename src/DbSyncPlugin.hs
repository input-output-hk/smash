{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module DbSyncPlugin
  ( poolMetadataDbSyncNodePlugin
  -- * For future testing
  , insertCardanoBlock
  ) where

import           Cardano.Prelude

import           Cardano.BM.Trace                            (Trace, logError,
                                                              logInfo)

import           Control.Monad.Logger                        (LoggingT)
import           Control.Monad.Trans.Except.Extra            (firstExceptT,
                                                              newExceptT,
                                                              runExceptT)
import           Control.Monad.Trans.Reader                  (ReaderT)

import           DB                                          (DBFail (..),
                                                              DataLayer (..),
                                                              postgresqlDataLayer)
import           Offline                                     (fetchInsertNewPoolMetadata)
import           Types                                       (PoolId (..), PoolMetadataHash (..),
                                                              PoolUrl (..))

import qualified Cardano.Chain.Block                         as Byron

import qualified Data.ByteString.Base16                      as B16

import           Database.Persist.Sql                        (IsolationLevel (..),
                                                              SqlBackend,
                                                              transactionSaveWithIsolation)

import qualified Cardano.Db.Insert                           as DB
import qualified Cardano.Db.Query                            as DB
import qualified Cardano.Db.Schema                           as DB

import           Cardano.DbSync.Error
import           Cardano.DbSync.Types                        as DbSync hiding ( ShelleyBlock )

import           Cardano.DbSync                              (DbSyncNodePlugin (..))

import Cardano.DbSync.Config.Types ( DbSyncEnv )
import qualified Cardano.DbSync.Era.Shelley.Util             as Shelley
import qualified Cardano.DbSync.Era.Byron.Util               as Byron

import           Shelley.Spec.Ledger.BaseTypes               (strictMaybeToMaybe)
import qualified Shelley.Spec.Ledger.BaseTypes               as Shelley
import qualified Shelley.Spec.Ledger.TxBody                  as Shelley

import           Ouroboros.Consensus.Byron.Ledger            (ByronBlock (..))
import           Ouroboros.Consensus.Shelley.Ledger.Block    (ShelleyBlock)
import           Ouroboros.Consensus.Shelley.Protocol.Crypto (StandardCrypto)
import           Ouroboros.Consensus.Cardano.Block           (HardForkBlock(..), ShelleyEra)

-- |Pass in the @DataLayer@.
poolMetadataDbSyncNodePlugin :: DbSyncNodePlugin
poolMetadataDbSyncNodePlugin =
  DbSyncNodePlugin
    { plugOnStartup = []
    , plugInsertBlock = [insertCardanoBlock postgresqlDataLayer]
    , plugRollbackBlock = []
    }

insertCardanoBlock dataLayer tracer _env _ block = do
  case block of
    BlockDetails (BlockByron blk) details -> Right <$> insertByronBlock tracer blk details
    BlockDetails (BlockShelley blk) _details -> insertShelleyBlock dataLayer tracer blk

-- We don't care about Byron, no pools there
insertByronBlock
    :: Trace IO Text -> ByronBlock -> DbSync.SlotDetails
    -> ReaderT SqlBackend (LoggingT IO) ()
insertByronBlock tracer blk _details = do
  case byronBlockRaw blk of
    Byron.ABOBBlock byronBlock -> do
        let slotNum = Byron.slotNumber byronBlock
        -- Output in intervals, don't add too much noise to the output.
        when (slotNum `mod` 5000 == 0) $
            liftIO . logInfo tracer $ "Byron block, slot: " <> show slotNum
    Byron.ABOBBoundary {} -> pure ()

  transactionSaveWithIsolation Serializable

insertShelleyBlock
    :: DataLayer
    -> Trace IO Text
    -> ShelleyBlock (ShelleyEra StandardCrypto)
    -> ReaderT SqlBackend (LoggingT IO) (Either DbSyncNodeError ())
insertShelleyBlock dataLayer tracer blk = do
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

    zipWithM_ (insertTx dataLayer tracer) [0 .. ] (Shelley.blockTxs blk)

    liftIO $ do
      logInfo tracer $ mconcat
        [ "insertShelleyBlock pool info: slot ", show (Shelley.slotNumber blk)
        , ", block ", show (Shelley.blockNumber blk)
        ]
    lift $ transactionSaveWithIsolation Serializable

insertTx
    :: (MonadIO m)
    => DataLayer
    -> Trace IO Text
    -> Word64
    -> ShelleyTx
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertTx dataLayer tracer _blockIndex tx =
    mapM_ (insertCertificate dataLayer tracer) (Shelley.txCertificates tx)


insertCertificate
    :: (MonadIO m)
    => DataLayer
    -> Trace IO Text
    -> (Word16, ShelleyDCert)
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertCertificate dataLayer tracer (_idx, cert) =
  case cert of
    Shelley.DCertDeleg _deleg ->
        liftIO $ logInfo tracer "insertCertificate: DCertDeleg"
    Shelley.DCertPool pool -> insertPoolCert dataLayer tracer pool
    Shelley.DCertMir _mir ->
        liftIO $ logInfo tracer "insertCertificate: DCertMir"
    Shelley.DCertGenesis _gen ->
        liftIO $ logError tracer "insertCertificate: Unhandled DCertGenesis certificate"

insertPoolCert
    :: (MonadIO m)
    => DataLayer
    -> Trace IO Text
    -> ShelleyPoolCert
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertPoolCert dataLayer tracer pCert =
  case pCert of
    Shelley.RegPool pParams -> insertPoolRegister dataLayer tracer pParams

    -- RetirePool (KeyHash 'StakePool era) _ = PoolId
    Shelley.RetirePool poolPubKey _epochNum -> do
        let poolIdHash = B16.encode . Shelley.unKeyHashRaw $ poolPubKey
        let poolId = PoolId . decodeUtf8 $ poolIdHash

        liftIO . logInfo tracer $ "Retiring pool with poolId: " <> show poolId

        let addRetiredPool = dlAddRetiredPool dataLayer

        eitherPoolId <- liftIO $ addRetiredPool poolId

        case eitherPoolId of
            Left err -> liftIO . logError tracer $ "Error adding retiring pool: " <> show err
            Right poolId' -> liftIO . logInfo tracer $ "Added retiring pool with poolId: " <> show poolId'

insertPoolRegister
    :: forall m. (MonadIO m)
    => DataLayer
    -> Trace IO Text
    -> ShelleyPoolParams
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertPoolRegister dataLayer tracer params = do
  let poolIdHash = B16.encode . Shelley.unKeyHashRaw $ Shelley._poolPubKey params
  let poolId = PoolId . decodeUtf8 $ poolIdHash

  liftIO . logInfo tracer $ "Inserting pool register with pool id: " <> decodeUtf8 poolIdHash
  case strictMaybeToMaybe $ Shelley._poolMD params of
    Just md -> do

        liftIO . logInfo tracer $ "Inserting metadata."
        let metadataUrl = PoolUrl . Shelley.urlToText $ Shelley._poolMDUrl md
        let metadataHash = PoolMetadataHash . decodeUtf8 . B16.encode $ Shelley._poolMDHash md

        -- Ah. We can see there is garbage all over the code. Needs refactoring.
        -- TODO(KS): Move this above!
        let addMetaDataReference = dlAddMetaDataReference dataLayer
        refId <- lift . liftIO $ addMetaDataReference poolId metadataUrl metadataHash

        liftIO $ fetchInsertNewPoolMetadata dataLayer tracer refId poolId md

        liftIO . logInfo tracer $ "Metadata inserted."

    Nothing -> pure ()

  liftIO . logInfo tracer $ "Inserted pool register."
  pure ()
