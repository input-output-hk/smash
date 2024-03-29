{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.SMASH.DBSyncPlugin
  ( poolMetadataDbSyncNodePlugin
  -- * For future testing
  , insertDefaultBlock
  -- * Utility for hashing pool metadata
  , hashPoolMetadata
  ) where

import           Cardano.Prelude

import           Cardano.BM.Trace                   (Trace, logDebug, logError,
                                                     logInfo)

import           Control.Monad.Logger               (LoggingT)
import           Control.Monad.Trans.Except.Extra   (firstExceptT, newExceptT)

import           Cardano.SMASH.DB                   (DBFail (..),
                                                     DataLayer (..))
import           Cardano.SMASH.Offline              (fetchInsertNewPoolMetadata)
import           Cardano.SMASH.Types                (PoolId (..),
                                                     PoolMetadataHash (..),
                                                     PoolUrl (..))

import           Cardano.Chain.Block                (ABlockOrBoundary (..))

import qualified Cardano.Crypto.Hash.Blake2b        as Crypto
import qualified Cardano.Crypto.Hash.Class          as Crypto
import qualified Data.ByteString.Base16             as B16

import           Database.Persist.Sql               (IsolationLevel (..),
                                                     SqlBackend,
                                                     transactionSaveWithIsolation)

import qualified Cardano.SMASH.DBSync.Db.Delete     as DB
import qualified Cardano.SMASH.DBSync.Db.Insert     as DB
import qualified Cardano.SMASH.DBSync.Db.Run        as DB
import qualified Cardano.SMASH.DBSync.Db.Schema     as DB
import qualified Cardano.SMASH.DBSync.Db.Query      as DB


import           Cardano.Sync.Error
import           Cardano.Sync.Types                 as DbSync

import           Cardano.Sync.LedgerState           (LedgerStateSnapshot (..),
                                                     applyBlock,
                                                     getAlonzoPParams,
                                                     saveCleanupState)

import           Cardano.Sync                       (SyncEnv (..),
                                                     SyncNodePlugin (..))
import           Cardano.Sync.Util


import qualified Cardano.DbSync.Era.Shelley.Generic as Generic
import qualified Cardano.DbSync.Era.Shelley.Generic as Shelley
import qualified Cardano.Sync.Era.Byron.Util        as Byron

import           Cardano.Slotting.Slot              (EpochNo (..),
                                                     EpochSize (..))

import           Cardano.Ledger.BaseTypes           (strictMaybeToMaybe)
import qualified Cardano.Ledger.BaseTypes           as Shelley
import qualified Shelley.Spec.Ledger.TxBody         as Shelley

import           Ouroboros.Consensus.Byron.Ledger   (ByronBlock (..))

import           Ouroboros.Consensus.Cardano.Block  (HardForkBlock (..),
                                                     StandardCrypto)

import           Ouroboros.Network.Block hiding (blockHash)
import           Ouroboros.Network.Point

-- |Pass in the @DataLayer@.
poolMetadataDbSyncNodePlugin :: DataLayer -> SyncNodePlugin
poolMetadataDbSyncNodePlugin dataLayer =
  SyncNodePlugin
    { plugOnStartup = []
    , plugInsertBlock = [insertDefaultBlocks dataLayer]
    , plugRollbackBlock = [rollbackDefaultBlocks]
    }

rollbackDefaultBlocks
    :: Trace IO Text
    -> DbSync.CardanoPoint
    -> IO (Either SyncNodeError ())
rollbackDefaultBlocks tracer point =
    DB.runDbAction Nothing $ runExceptT action
  where
    action :: MonadIO m => ExceptT SyncNodeError (ReaderT SqlBackend m) ()
    action = do
      xs <- lift $ slotsToDelete (pointSlot point)
      if null xs then
          liftIO $ logInfo tracer "No Rollback is necessary"
      else do
          liftIO . logInfo tracer $
                mconcat
                  [ "Deleting ", textShow (length xs), " slots: ", renderSlotList xs
                  ]
          mapM_ (lift . DB.deleteCascadeSlotNo) (unSlotNo <$> xs)
          liftIO $ logInfo tracer "Slots deleted"

    slotsToDelete Origin = DB.querySlotNos
    slotsToDelete (At sl) = DB.querySlotNosGreaterThan (unSlotNo sl)

-- For information on what era we are in.
data BlockName
    = Shelley
    | Allegra
    | Mary
    | Alonzo
    deriving (Eq, Show)

insertDefaultBlocks
    :: DataLayer
    -> Trace IO Text
    -> SyncEnv
    -> [BlockDetails]
    -> IO (Either SyncNodeError ())
insertDefaultBlocks dataLayer tracer env blockDetails =
    DB.runDbAction (Just tracer) $
      traverseMEither (\blockDetail -> insertDefaultBlock dataLayer tracer env blockDetail) blockDetails

-- |TODO(KS): We need to abstract over these blocks so we can test this functionality
-- separatly from the actual blockchain, using tests only.
insertDefaultBlock
    :: DataLayer
    -> Trace IO Text
    -> SyncEnv
    -> BlockDetails
    -> ReaderT SqlBackend (LoggingT IO) (Either SyncNodeError ())
insertDefaultBlock dataLayer tracer env (BlockDetails cblk details) = do

    -- Calculate the new ledger state to pass to the DB insert functions but do not yet
    -- update ledgerStateVar.
    lStateSnap <- liftIO $ applyBlock (envLedger env) cblk details
    mkSnapshotMaybe lStateSnap (isSyncedWithinSeconds details 60)
    res <- case cblk of
              BlockByron blk -> do
                insertByronBlock tracer blk details
              BlockShelley blk -> do
                insertShelleyBlock Shelley dataLayer tracer env (Generic.fromShelleyBlock blk) details
              BlockAllegra blk -> do
                insertShelleyBlock Allegra dataLayer tracer env (Generic.fromAllegraBlock blk) details
              BlockMary blk -> do
                insertShelleyBlock Mary dataLayer tracer env (Generic.fromMaryBlock blk) details
              BlockAlonzo blk -> do
                let pp = getAlonzoPParams $ lssState lStateSnap
                insertShelleyBlock Alonzo dataLayer tracer env (Generic.fromAlonzoBlock pp blk) details

    pure res
  where

    mkSnapshotMaybe snapshot syncState =
      whenJust (lssNewEpoch snapshot) $ \newEpoch -> do
        let newEpochNo = Generic.neEpoch newEpoch
        liftIO $ saveCleanupState (envLedger env) (lssOldState snapshot) syncState  (Just $ newEpochNo - 1)


-- We don't care about Byron, no pools there
insertByronBlock
    :: Trace IO Text
    -> ByronBlock
    -> DbSync.SlotDetails
    -> ReaderT SqlBackend (LoggingT IO) (Either SyncNodeError ())
insertByronBlock tracer blk details = do
  case byronBlockRaw blk of
    ABOBBlock byronBlock -> do
        let blockHash = Byron.blockHash byronBlock
        let slotNum = Byron.slotNumber byronBlock
        let blockNumber = Byron.blockNumber byronBlock

        -- Output in intervals, don't add too much noise to the output.
        when (slotNum `mod` 5000 == 0) $
            liftIO . logInfo tracer $ mconcat
                [ "Byron block: epoch ", show (unEpochNo $ sdEpochNo details), ", slot " <> show slotNum
                ]

        -- TODO(KS): Move to DataLayer.
        _blkId <- DB.insertBlock $
                  DB.Block
                    { DB.blockHash = blockHash
                    , DB.blockEpochNo = Just $ unEpochNo (sdEpochNo details)
                    , DB.blockSlotNo = Just $ slotNum
                    , DB.blockBlockNo = Just $ blockNumber
                    }

        return ()

    ABOBBoundary {} -> pure ()

  return $ Right ()

-- Here we insert pools.
insertShelleyBlock
    :: BlockName
    -> DataLayer
    -> Trace IO Text
    -> SyncEnv
    -> Generic.Block
    -> SlotDetails
    -> ReaderT SqlBackend (LoggingT IO) (Either SyncNodeError ())
insertShelleyBlock blockName dataLayer tracer env blk details = do

  runExceptT $ do

    let blockNumber = Generic.blkBlockNo blk

    -- TODO(KS): Move to DataLayer.
    _blkId <- lift . DB.insertBlock $
                  DB.Block
                    { DB.blockHash = Shelley.blkHash blk
                    , DB.blockEpochNo = Just $ unEpochNo (sdEpochNo details)
                    , DB.blockSlotNo = Just $ unSlotNo (Generic.blkSlotNo blk)
                    , DB.blockBlockNo = Just $ unBlockNo blockNumber
                    }

    zipWithM_ (insertTx dataLayer blockNumber tracer env) [0 .. ] (Shelley.blkTxs blk)

    liftIO $ do
      let epoch = unEpochNo (sdEpochNo details)
          slotWithinEpoch = unEpochSlot (sdEpochSlot details)
          globalSlot = epoch * (unEpochSize $ sdEpochSize details) + slotWithinEpoch

      when (slotWithinEpoch `mod` 1000 == 0) $
        logInfo tracer $ mconcat
          [ "Insert '", show blockName
          , "' block pool info: epoch ", show epoch
          , ", slot ", show slotWithinEpoch
          , ", block ", show blockNumber
          , ", global slot ", show globalSlot
          ]

    lift $ transactionSaveWithIsolation Serializable

insertTx
    :: (MonadIO m)
    => DataLayer
    -> BlockNo
    -> Trace IO Text
    -> SyncEnv
    -> Word64
    -> Generic.Tx
    -> ExceptT SyncNodeError m ()
insertTx dataLayer blockNumber tracer env _blockIndex tx =
    mapM_ (insertCertificate dataLayer blockNumber tracer env) $ Generic.txCertificates tx

insertCertificate
    :: (MonadIO m)
    => DataLayer
    -> BlockNo
    -> Trace IO Text
    -> SyncEnv
    -> Generic.TxCertificate
    -> ExceptT SyncNodeError m ()
insertCertificate dataLayer blockNumber tracer _env (Generic.TxCertificate _ _idx cert) =
  case cert of
    Shelley.DCertDeleg _deleg ->
        -- Since at some point we start to have a large number of delegation
        -- certificates, this should be output just in debug mode.
        liftIO $ logDebug tracer "insertCertificate: DCertDeleg"
    Shelley.DCertPool pool ->
        insertPoolCert dataLayer blockNumber tracer pool
    Shelley.DCertMir _mir ->
        liftIO $ logInfo tracer "insertCertificate: DCertMir"
    Shelley.DCertGenesis _gen ->
        liftIO $ logError tracer "insertCertificate: Unhandled DCertGenesis certificate"

insertPoolCert
    :: (MonadIO m)
    => DataLayer
    -> BlockNo
    -> Trace IO Text
    -> Shelley.PoolCert StandardCrypto
    -> ExceptT SyncNodeError m ()
insertPoolCert dataLayer blockNumber tracer pCert =
  case pCert of
    Shelley.RegPool pParams -> do
        let poolIdHash = B16.encode . Generic.unKeyHashRaw $ Shelley._poolId pParams
        let poolId = PoolId . decodeUtf8 $ poolIdHash

        -- Insert pool id
        let addPool = dlAddPool dataLayer
        addedPool <- liftIO $ addPool poolId

        case addedPool of
          Left _err -> liftIO . logInfo tracer $ "Pool already registered with pool id: " <> decodeUtf8 poolIdHash
          Right _pool -> liftIO . logInfo tracer $ "Inserting pool register with pool id: " <> decodeUtf8 poolIdHash

        -- TODO(KS): Check whether the pool is retired, and if yes,
        -- if the current block number is greater, remove that record.
        let checkRetiredPool = dlCheckRetiredPool dataLayer
        retiredPoolId <- liftIO $ checkRetiredPool poolId

        -- This could be chained, revives the pool if it was re-submited when already being retired.
        case retiredPoolId of
            Left _err -> liftIO . logInfo tracer $ "Pool not retired: " <> decodeUtf8 poolIdHash
            Right (poolId', retiredPoolBlockNo) ->
                -- This is a superfluous check, like this word, but could be relevent in some cases.
                if (retiredPoolBlockNo > unBlockNo blockNumber)
                    then liftIO . logInfo tracer $ "Pool retired after this block, not reviving: " <> decodeUtf8 poolIdHash
                    else do
                        -- REVIVE retired pool
                        let removeRetiredPool = dlRemoveRetiredPool dataLayer
                        removedPoolId <- liftIO $ removeRetiredPool poolId'

                        case removedPoolId of
                            Left err -> liftIO . logInfo tracer $ "Pool retired, not revived. " <> show err
                            Right removedPoolId' -> liftIO . logInfo tracer $ "Pool retired, revived: " <> show removedPoolId'

        -- Finally, insert the metadata!
        insertPoolRegister dataLayer tracer pParams

    -- RetirePool (KeyHash 'StakePool era) _ = PoolId
    Shelley.RetirePool poolPubKey _epochNum -> do
        let poolIdHash = B16.encode . Generic.unKeyHashRaw $ poolPubKey
        let poolId = PoolId . decodeUtf8 $ poolIdHash

        liftIO . logInfo tracer $ "Retiring pool with poolId: " <> show poolId

        let addRetiredPool = dlAddRetiredPool dataLayer

        eitherPoolId <- liftIO $ addRetiredPool poolId (unBlockNo blockNumber)

        case eitherPoolId of
            Left err -> liftIO . logError tracer $ "Error adding retiring pool: " <> show err
            Right poolId' -> liftIO . logInfo tracer $ "Added retiring pool with poolId: " <> show poolId'

insertPoolRegister
    :: forall m. (MonadIO m)
    => DataLayer
    -> Trace IO Text
    -> Shelley.PoolParams StandardCrypto
    -> ExceptT SyncNodeError m ()
insertPoolRegister dataLayer tracer params = do
  let poolIdHash = B16.encode . Generic.unKeyHashRaw $ Shelley._poolId params
  let poolId = PoolId . decodeUtf8 $ poolIdHash

  case strictMaybeToMaybe $ Shelley._poolMD params of
    Just md -> do

        liftIO . logInfo tracer $ "Inserting metadata."
        let metadataUrl = PoolUrl . Shelley.urlToText $ Shelley._poolMDUrl md
        let metadataHash = PoolMetadataHash . decodeUtf8 . B16.encode $ Shelley._poolMDHash md

        let addMetaDataReference = dlAddMetaDataReference dataLayer

        -- We need to map this to ExceptT
        refId <- firstExceptT (\(e :: DBFail) -> NEError $ show e) . newExceptT . liftIO $
            addMetaDataReference poolId metadataUrl metadataHash

        liftIO $ fetchInsertNewPoolMetadata dataLayer tracer refId poolId md

        liftIO . logInfo tracer $ "Metadata inserted."

    Nothing -> pure ()

  liftIO . logInfo tracer $ "Inserted pool register."
  pure ()

-- | Returns a hash from the pool metadata.
hashPoolMetadata :: Text -> ByteString
hashPoolMetadata poolMetadata =
    B16.encode $ Crypto.digest (Proxy :: Proxy Crypto.Blake2b_256) (encodeUtf8 poolMetadata)

