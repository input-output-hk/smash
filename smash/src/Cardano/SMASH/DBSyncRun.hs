{-# LANGUAGE MultiParamTypeClasses #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.SMASH.DBSyncRun
    ( runCardanoSyncWithSmash
    , setupTraceFromConfig
    ) where

import           Cardano.Prelude                   hiding (Meta)

import qualified Data.ByteString.Char8             as BS

import           Data.Time.Clock                   (UTCTime (..))
import qualified Data.Time.Clock                   as Time

import           Control.Monad.Trans.Except.Extra  (firstExceptT, left,
                                                    newExceptT)

import qualified Cardano.SMASH.DB                  as DB
import           Cardano.SMASH.Offline             (runOfflineFetchThread)

import           Cardano.SMASH.Lib
import           Cardano.SMASH.Types

import           Cardano.Sync.Config
import           Cardano.Sync.Config.Types
import           Cardano.Sync.Error

import           Cardano.Sync                      (Block (..), MetricSetters,
                                                    SyncDataLayer (..),
                                                    runSyncNode)
import           Cardano.Sync.Database             (runDbThread)

import           Control.Monad.Trans.Maybe

import           Database.Esqueleto

import qualified Cardano.BM.Setup                  as Logging
import           Cardano.BM.Trace                  (Trace, logInfo, modifyName)
import           Cardano.SMASH.DBSyncPlugin        (poolMetadataDbSyncNodePlugin)
import           Cardano.Slotting.Slot             (EpochNo (..), SlotNo (..))

import           Ouroboros.Consensus.Cardano.Block (StandardShelley)
import           Ouroboros.Consensus.Shelley.Node  (ShelleyGenesis (..))
import           Ouroboros.Network.Block           (BlockNo (..))
import qualified Shelley.Spec.Ledger.Genesis       as Shelley

---------------------------------------------------------------------------------------------------

data CardanoSyncError = CardanoSyncError !Text
    deriving (Eq, Show)

cardanoSyncErrorToNodeError :: CardanoSyncError -> SyncNodeError
cardanoSyncErrorToNodeError (CardanoSyncError err) = NEError err

dbFailToCardanoSyncError :: Either DBFail a -> Either CardanoSyncError a
dbFailToCardanoSyncError (Left dbFail)  = Left . CardanoSyncError . DB.renderLookupFail $ dbFail
dbFailToCardanoSyncError (Right aValue) = Right aValue

cardanoSyncError :: Monad m => Text -> ExceptT CardanoSyncError m a
cardanoSyncError = left . CardanoSyncError

-------------------------------------------------------------------------------

-- Util data structure.
data Meta = Meta
    { mStartTime   :: !UTCTime
    , mNetworkName :: !(Maybe Text)
    } deriving (Eq, Show)

-- @Word64@ is valid as well.
newtype BlockId = BlockId Int
    deriving (Eq, Show)

-- @Word64@ is valid as well.
newtype MetaId = MetaId Int
    deriving (Eq, Show)

-------------------------------------------------------------------------------

instance DBConversion DB.Meta Meta where
    convertFromDB meta =
        Meta
            { mStartTime = DB.metaStartTime meta
            , mNetworkName = DB.metaNetworkName meta
            }

    convertToDB meta =
        DB.Meta
            { DB.metaStartTime = mStartTime meta
            , DB.metaNetworkName = mNetworkName meta
            }

-------------------------------------------------------------------------------

setupTraceFromConfig :: ConfigFile -> IO (Trace IO Text)
setupTraceFromConfig configFile = do
    enc <- readSyncNodeConfig configFile
    trce <- Logging.setupTrace (Right $ dncLoggingConfig enc) "smash-node"
    return trce

-------------------------------------------------------------------------------

-- Running SMASH with cardano-sync.
runCardanoSyncWithSmash :: Maybe FilePath -> MetricSetters -> SyncNodeParams -> IO ()
runCardanoSyncWithSmash mMigrationDir metricsSetters dbSyncNodeParams = do

    -- Setup trace
    let configFile = enpConfigFile dbSyncNodeParams
    tracer <- setupTraceFromConfig configFile

    let (MigrationDir migrationDir') = enpMigrationDir dbSyncNodeParams

    let smashMigrationDir = DB.SmashMigrationDir $ fromMaybe migrationDir' mMigrationDir

    -- Run migrations
    logInfo tracer $ "Running migrations."
    DB.runMigrations tracer (\x -> x) smashMigrationDir (Just $ DB.SmashLogFileDir "/tmp")
    logInfo tracer $ "Migrations complete."

    let dataLayer = DB.postgresqlDataLayer (Just tracer)

    -- The plugin requires the @DataLayer@.
    let smashDbSyncNodePlugin = poolMetadataDbSyncNodePlugin dataLayer

    let getLatestBlock =
            runMaybeT $ do
                block <- MaybeT $ DB.runDbIohkLogging tracer DB.queryLatestBlock
                return block

    -- The base @DataLayer@.
    let syncDataLayer =
            SyncDataLayer
                { sdlGetSlotHash = \slotNo -> do
                    slotHash <- DB.runDbIohkLogging tracer $ DB.querySlotHash slotNo
                    case slotHash of
                        Nothing           -> return []
                        Just slotHashPair -> return [slotHashPair]

                , sdlGetLatestBlock = runMaybeT $ do
                    block <- MaybeT getLatestBlock

                    return $ Block
                        { bHash = DB.blockHash block
                        , bEpochNo = EpochNo . fromMaybe 0 $ DB.blockEpochNo block
                        , bSlotNo = SlotNo . fromMaybe 0 $ DB.blockSlotNo block
                        , bBlockNo = BlockNo . fromMaybe 0 $ DB.blockBlockNo block
                        }

                , sdlGetLatestSlotNo = SlotNo <$> DB.runDbNoLogging DB.queryLatestSlotNo

                }

    -- The actual DB Thread.
    let runDBThreadFunction =
            \tracer' env plugin metrics' actionQueue ->
                race_
                    (runDbThread tracer' env plugin metrics' actionQueue)
                    (runOfflineFetchThread $ modifyName (const "fetch") tracer')

    let runInsertValidateGenesisSmashFunction = insertValidateGenesisSmashFunction syncDataLayer

    let runSmashSyncNode =
            runSyncNode
                syncDataLayer
                metricsSetters
                tracer
                smashDbSyncNodePlugin
                dbSyncNodeParams
                runInsertValidateGenesisSmashFunction
                runDBThreadFunction

    race_
        runSmashSyncNode
        (runApp dataLayer defaultConfiguration)

---------------------------------------------------------------------------------------------------

insertValidateGenesisSmashFunction
    :: SyncDataLayer
    -> Trace IO Text
    -> NetworkName
    -> GenesisConfig
    -> ExceptT SyncNodeError IO ()
insertValidateGenesisSmashFunction dataLayer tracer networkName genCfg =
    firstExceptT cardanoSyncErrorToNodeError $ case genCfg of
        GenesisCardano _ _bCfg sCfg ->
            insertValidateGenesisDistSmash dataLayer tracer networkName (scConfig sCfg)

-- | Idempotent insert the initial Genesis distribution transactions into the DB.
-- If these transactions are already in the DB, they are validated.
insertValidateGenesisDistSmash
    :: SyncDataLayer
    -> Trace IO Text
    -> NetworkName
    -> ShelleyGenesis StandardShelley
    -> ExceptT CardanoSyncError IO ()
insertValidateGenesisDistSmash _dataLayer tracer (NetworkName networkName) cfg = do
    newExceptT $ insertAtomicAction
  where
    insertAtomicAction :: IO (Either CardanoSyncError ())
    insertAtomicAction = do
      let getBlockId = \genesisHash -> runExceptT $ do
                    blockId <- ExceptT $ dbFailToCardanoSyncError <$> (DB.runDbIohkLogging tracer $ DB.queryBlockId genesisHash)
                    return . BlockId . fromIntegral . fromSqlKey $ blockId
      ebid <- getBlockId (configGenesisHash cfg)

      case ebid of
        -- TODO(KS): This needs to be moved into DataLayer.
        Right _bid -> runExceptT $ do
            liftIO $ logInfo tracer "Validating Genesis distribution"

            let getMeta = runExceptT $ do
                    meta <- ExceptT $ dbFailToCardanoSyncError <$> (DB.runDbIohkLogging tracer DB.queryMeta)
                    return $ Meta
                        { mStartTime = DB.metaStartTime meta
                        , mNetworkName = DB.metaNetworkName meta
                        }

            meta <- newExceptT getMeta

            newExceptT $ validateGenesisDistribution tracer meta networkName cfg

        Left _ -> do
            liftIO $ logInfo tracer "Inserting Genesis distribution"

            let meta =  Meta
                            { mStartTime = configStartTime cfg
                            , mNetworkName = Just networkName
                            }

            let block = DB.Block
                            { DB.blockHash = configGenesisHash cfg
                            , DB.blockEpochNo = Just 0
                            , DB.blockSlotNo = Just 0
                            , DB.blockBlockNo = Just 0
                            }

            let addGenesisMetaBlock = DB.dlAddGenesisMetaBlock (DB.postgresqlDataLayer (Just tracer))
            metaIdBlockIdE <- addGenesisMetaBlock (convertToDB meta) block

            case metaIdBlockIdE of
                Right (_metaId, _blockId) -> pure $ Right ()
                Left err                  -> pure . Left . CardanoSyncError $ show err

-- | Validate that the initial Genesis distribution in the DB matches the Genesis data.
validateGenesisDistribution
    :: (MonadIO m)
    => Trace IO Text
    -> Meta
    -> Text
    -> ShelleyGenesis StandardShelley
    -> m (Either CardanoSyncError ())
validateGenesisDistribution _tracer meta networkName cfg =
  runExceptT $ do

    -- Show configuration we are validating
    print cfg

    when (mStartTime meta /= configStartTime cfg) $
      cardanoSyncError $ mconcat
            [ "Shelley: Mismatch chain start time. Config value "
            , textShow (configStartTime cfg)
            , " does not match DB value of ", textShow (mStartTime meta)
            ]

    case mNetworkName meta of
      Nothing ->
        cardanoSyncError $ "Shelley.validateGenesisDistribution: Missing network name"
      Just name ->
        when (name /= networkName) $
          cardanoSyncError $ mconcat
              [ "Shelley.validateGenesisDistribution: Provided network name "
              , networkName
              , " does not match DB value "
              , name
              ]

---------------------------------------------------------------------------------------------------

textShow :: Show a => a -> Text
textShow = show

configStartTime :: ShelleyGenesis StandardShelley -> UTCTime
configStartTime = roundToMillseconds . Shelley.sgSystemStart

roundToMillseconds :: UTCTime -> UTCTime
roundToMillseconds (UTCTime day picoSecs) =
    UTCTime day (Time.picosecondsToDiffTime $ 1000000 * (picoSeconds `div` 1000000))
  where
    picoSeconds :: Integer
    picoSeconds = Time.diffTimeToPicoseconds picoSecs

configGenesisHash :: ShelleyGenesis StandardShelley -> ByteString
configGenesisHash _ = BS.take 32 ("GenesisHash " <> BS.replicate 32 '\0')

---------------------------------------------------------------------------------------------------

