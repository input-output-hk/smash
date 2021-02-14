{-# LANGUAGE CPP                   #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances  #-}

-- The db conversion.
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main where

import           Cardano.Prelude                   hiding (Meta)

import qualified Data.ByteString.Char8             as BS

import           Control.Monad.Trans.Except.Extra  (firstExceptT, left,
                                                    newExceptT)

import qualified Cardano.SMASH.DB                  as DB
import           Cardano.SMASH.Offline             (runOfflineFetchThread)

import           Cardano.SMASH.Lib
import           Cardano.SMASH.Types

import           Cardano.Sync.Config
import           Cardano.Sync.Config.Types
import           Cardano.Sync.Error

import           Cardano.Sync                      (Block (..), ConfigFile (..),
                                                    Meta (..), SocketPath (..),
                                                    SyncDataLayer (..),
                                                    runSyncNode)
import           Cardano.Sync.Database             (runDbThread)

import           Control.Applicative               (optional)
import           Control.Monad.Trans.Maybe

import           Data.Monoid                       ((<>))
import           Database.Esqueleto

import           Options.Applicative               (Parser, ParserInfo,
                                                    ParserPrefs)
import qualified Options.Applicative               as Opt

import           System.FilePath                   ((</>))

import qualified Cardano.BM.Setup                  as Logging
import           Cardano.BM.Trace                  (Trace, logInfo, modifyName)
import           Cardano.Slotting.Slot             (SlotNo (..))
import           Cardano.SMASH.DBSyncPlugin        (poolMetadataDbSyncNodePlugin)

import           Ouroboros.Consensus.Cardano.Block (StandardShelley)
import           Ouroboros.Consensus.Shelley.Node  (ShelleyGenesis (..))
import qualified Shelley.Spec.Ledger.Genesis       as Shelley

import           Data.Time.Clock                   (UTCTime (..))
import qualified Data.Time.Clock                   as Time


main :: IO ()
main = do
    Opt.customExecParser p opts >>= runCommand
  where
    opts :: ParserInfo Command
    opts = Opt.info (Opt.helper <*> pVersion <*> pCommand)
      ( Opt.fullDesc
      <> Opt.header "SMASH - manage the Stakepool Metadata Aggregation Server"
      )

    p :: ParserPrefs
    p = Opt.prefs Opt.showHelpOnEmpty

-- -----------------------------------------------------------------------------

data Command
  = CreateAdminUser !ApplicationUser
  | DeleteAdminUser !ApplicationUser
  | CreateMigration !MigrationDir
  | RunMigrations !ConfigFile !MigrationDir !(Maybe LogFileDir)
  | ForceResync !ConfigFile !MigrationDir !(Maybe LogFileDir)
  | RunApplication !ConfigFile
#ifdef TESTING_MODE
  | RunStubApplication
#endif
  | RunApplicationWithDbSync SyncNodeParams

setupTraceFromConfig :: ConfigFile -> IO (Trace IO Text)
setupTraceFromConfig configFile = do
    enc <- readSyncNodeConfig configFile
    trce <- Logging.setupTrace (Right $ dncLoggingConfig enc) "smash-node"
    return trce

runCommand :: Command -> IO ()
runCommand cmd =
  case cmd of
    CreateAdminUser applicationUser -> do

        let dataLayer :: DB.DataLayer
            dataLayer = DB.postgresqlDataLayer Nothing

        adminUserE <- createAdminUser dataLayer applicationUser
        case adminUserE of
            Left err -> panic $ DB.renderLookupFail err
            Right adminUser -> putTextLn $ "Created admin user: " <> show adminUser

    DeleteAdminUser applicationUser -> do

        let dataLayer :: DB.DataLayer
            dataLayer = DB.postgresqlDataLayer Nothing

        adminUserE <- deleteAdminUser dataLayer applicationUser
        case adminUserE of
            Left err -> panic $ DB.renderLookupFail err
            Right adminUser -> putTextLn $ "Deleted admin user: " <> show adminUser

    CreateMigration mdir -> doCreateMigration mdir

    RunMigrations configFile (MigrationDir mdir) mldir -> do
        trce <- setupTraceFromConfig configFile
        let smashLogFileDir =
                case mldir of
                    Nothing               -> Nothing
                    Just (LogFileDir dir) -> return $ DB.SmashLogFileDir dir
        DB.runMigrations trce (\pgConfig -> pgConfig) (DB.SmashMigrationDir mdir) smashLogFileDir

    -- We could reuse the log file dir in the future
    ForceResync configFile (MigrationDir mdir) _mldir -> do
        trce <- setupTraceFromConfig configFile
        pgConfig <- DB.readPGPassFileEnv

        -- Just run the force-resync which deletes all the state tables.
        DB.runSingleScript trce pgConfig (mdir </> "force-resync.sql")

    RunApplication configFile -> do
        trce <- setupTraceFromConfig configFile

        let dataLayer :: DB.DataLayer
            dataLayer = DB.postgresqlDataLayer (Just trce)

        runApp dataLayer defaultConfiguration
#ifdef TESTING_MODE
    RunStubApplication -> runAppStubbed defaultConfiguration
#endif
    RunApplicationWithDbSync dbSyncNodeParams -> runCardanoSyncWithSmash dbSyncNodeParams

renderCardanoSyncError :: CardanoSyncError -> Text
renderCardanoSyncError (CardanoSyncError cardanoSyncError') = cardanoSyncError'

cardanoSyncError :: Monad m => Text -> ExceptT CardanoSyncError m a
cardanoSyncError = left . CardanoSyncError

-- @Word64@ is valid as well.
newtype BlockId = BlockId Int
    deriving (Eq, Show)

-- @Word64@ is valid as well.
newtype MetaId = MetaId Int
    deriving (Eq, Show)

-- Running SMASH with cardano-sync.
runCardanoSyncWithSmash :: SyncNodeParams -> IO ()
runCardanoSyncWithSmash dbSyncNodeParams = do

    -- Setup trace
    let configFile = enpConfigFile dbSyncNodeParams
    tracer <- setupTraceFromConfig configFile

    let (MigrationDir migrationDir') = enpMigrationDir dbSyncNodeParams

    -- Run migrations
    logInfo tracer $ "Running migrations."
    DB.runMigrations tracer (\x -> x) (DB.SmashMigrationDir migrationDir') (Just $ DB.SmashLogFileDir "/tmp")
    logInfo tracer $ "Migrations complete."

    -- Run metrics server
    --(metrics, server) <- registerMetricsServer 8080

    let dataLayer :: DB.DataLayer
        dataLayer = DB.postgresqlDataLayer (Just tracer)

    -- The plugin requires the @DataLayer@.
    let smashDbSyncNodePlugin = poolMetadataDbSyncNodePlugin dataLayer

    let getLatestBlock =
            runMaybeT $ do
                block <- MaybeT $ DB.runDbIohkLogging tracer DB.queryLatestBlock
                return $ convertFromDB block

    -- The base @DataLayer@.
    let syncDataLayer =
            SyncDataLayer
                { sdlGetSlotHash = \slotNo -> do
                    slotHash <- DB.runDbIohkLogging tracer $ DB.querySlotHash slotNo
                    case slotHash of
                        Nothing -> return []
                        Just slotHashPair -> return [slotHashPair]

                , sdlGetLatestBlock = getLatestBlock

                , sdlGetLatestSlotNo = SlotNo <$> DB.runDbNoLogging DB.queryLatestSlotNo

                }

    -- The actual DB Thread.
    let runDBThreadFunction =
            \tracer' env plugin metrics' actionQueue ->
                race_
                    (runDbThread tracer' env plugin metrics' actionQueue)
                    (runOfflineFetchThread $ modifyName (const "fetch") tracer')

    let runInsertValidateGenesisSmashFunction = insertValidateGenesisSmashFunction syncDataLayer

    race_
        (runSyncNode syncDataLayer tracer smashDbSyncNodePlugin dbSyncNodeParams runInsertValidateGenesisSmashFunction runDBThreadFunction)
        (runApp dataLayer defaultConfiguration)


data CardanoSyncError = CardanoSyncError Text
    deriving (Eq, Show)

cardanoSyncErrorToNodeError :: CardanoSyncError -> SyncNodeError
cardanoSyncErrorToNodeError (CardanoSyncError err) = NEError err

dbFailToCardanoSyncError :: Either DBFail a -> Either CardanoSyncError a
dbFailToCardanoSyncError (Left dbFail)  = Left . CardanoSyncError . DB.renderLookupFail $ dbFail
dbFailToCardanoSyncError (Right aValue) = Right aValue

doCreateMigration :: MigrationDir -> IO ()
doCreateMigration (MigrationDir mdir) = do
  mfp <- DB.createMigration . DB.SmashMigrationDir $ mdir
  case mfp of
    Nothing -> putTextLn "No migration needed."
    Just fp -> putTextLn $ toS ("New migration '" ++ fp ++ "' created.")

-------------------------------------------------------------------------------

instance DBConversion DB.Block Block where
    convertFromDB block =
        Block
            { bHash = DB.blockHash block
            , bEpochNo = DB.blockEpochNo block
            , bSlotNo = DB.blockSlotNo block
            , bBlockNo = DB.blockBlockNo block
            }

    convertToDB block =
        DB.Block
            { DB.blockHash = bHash block
            , DB.blockEpochNo = bEpochNo block
            , DB.blockSlotNo = bSlotNo block
            , DB.blockBlockNo = bBlockNo block
            }

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

            let block = Block
                            { bHash = configGenesisHash cfg
                            , bEpochNo = Nothing
                            , bSlotNo = Nothing
                            , bBlockNo = Nothing
                            }

            let addGenesisMetaBlock = DB.dlAddGenesisMetaBlock (DB.postgresqlDataLayer $ Just tracer)
            metaIdBlockIdE <- addGenesisMetaBlock (convertToDB meta) (convertToDB block)

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
validateGenesisDistribution tracer meta networkName cfg =
  runExceptT $ do
    liftIO $ logInfo tracer "Validating Genesis distribution"

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

pCommandLine :: Parser SyncNodeParams
pCommandLine =
  SyncNodeParams
    <$> pConfigFile
    <*> pSocketPath
    <*> pLedgerStateDir
    <*> pMigrationDir
    <*> optional pSlotNo

pConfigFile :: Parser ConfigFile
pConfigFile =
  ConfigFile <$> Opt.strOption
    ( Opt.long "config"
    <> Opt.help "Path to the db-sync node config file"
    <> Opt.completer (Opt.bashCompleter "file")
    <> Opt.metavar "FILEPATH"
    )

pLedgerStateDir :: Parser LedgerStateDir
pLedgerStateDir =
  LedgerStateDir <$> Opt.strOption
    (  Opt.long "state-dir"
    <> Opt.help "The directory for persisting ledger state."
    <> Opt.completer (Opt.bashCompleter "directory")
    <> Opt.metavar "FILEPATH"
    )

pMigrationDir :: Parser MigrationDir
pMigrationDir =
  MigrationDir <$> Opt.strOption
    (  Opt.long "schema-dir"
    <> Opt.help "The directory containing the migrations."
    <> Opt.completer (Opt.bashCompleter "directory")
    <> Opt.metavar "FILEPATH"
    )

pSocketPath :: Parser SocketPath
pSocketPath =
  SocketPath <$> Opt.strOption
    ( Opt.long "socket-path"
    <> Opt.help "Path to a cardano-node socket"
    <> Opt.completer (Opt.bashCompleter "file")
    <> Opt.metavar "FILEPATH"
    )

pSlotNo :: Parser SlotNo
pSlotNo =
  SlotNo <$> Opt.option Opt.auto
    (  Opt.long "rollback-to-slot"
    <> Opt.help "Force a rollback to the specified slot (mainly for testing and debugging)."
    <> Opt.metavar "WORD"
    )

-- TOOD(KS): Fix this to pick up a proper version.
pVersion :: Parser (a -> a)
pVersion =
  Opt.infoOption "SMASH version 1.3.0"
    (  Opt.long "version"
    <> Opt.short 'v'
    <> Opt.help "Print the version and exit"
    )

pCommand :: Parser Command
pCommand =
  Opt.subparser
    ( Opt.command "create-admin-user"
        ( Opt.info pCreateAdmin
          $ Opt.progDesc "Creates an admin user. Requires database."
          )
    <> Opt.command "delete-admin-user"
        ( Opt.info pDeleteAdmin
          $ Opt.progDesc "Deletes an admin user. Requires database."
          )
    <> Opt.command "create-migration"
        ( Opt.info pCreateMigration
          $ Opt.progDesc "Create a database migration (only really used by devs)."
          )
    <> Opt.command "run-migrations"
        ( Opt.info pRunMigrations
          $ Opt.progDesc "Run the database migrations (which are idempotent)."
          )
    <> Opt.command "force-resync"
        ( Opt.info pForceResync
          $ Opt.progDesc "Clears all the block information and forces a resync."
          )
    <> Opt.command "run-app"
        ( Opt.info pRunApp
          $ Opt.progDesc "Run the application that just serves the pool info."
          )
#ifdef TESTING_MODE
    <> Opt.command "run-stub-app"
        ( Opt.info pRunStubApp
          $ Opt.progDesc "Run the stub application that just serves the pool info."
          )
#endif
    <> Opt.command "run-app-with-db-sync"
        ( Opt.info pRunAppWithDbSync
          $ Opt.progDesc "Run the application that syncs up the pool info and serves it."
          )
    )
  where

    pCreateAdmin :: Parser Command
    pCreateAdmin =
        CreateAdminUser <$> pApplicationUser

    pDeleteAdmin :: Parser Command
    pDeleteAdmin =
        DeleteAdminUser <$> pApplicationUser

    pCreateMigration :: Parser Command
    pCreateMigration =
        CreateMigration <$> pSmashMigrationDir

    pRunMigrations :: Parser Command
    pRunMigrations =
        RunMigrations <$> pConfigFile <*> pSmashMigrationDir <*> optional pLogFileDir

    pForceResync :: Parser Command
    pForceResync =
        ForceResync <$> pConfigFile <*> pSmashMigrationDir <*> optional pLogFileDir

    -- Empty right now but we might add some params over time. Like ports and stuff?
    pRunApp :: Parser Command
    pRunApp =
        RunApplication <$> pConfigFile

#ifdef TESTING_MODE
    pRunStubApp :: Parser Command
    pRunStubApp =
        pure RunStubApplication
#endif

    -- Empty right now but we might add some params over time. Like ports and stuff?
    pRunAppWithDbSync :: Parser Command
    pRunAppWithDbSync =
        RunApplicationWithDbSync <$> pCommandLine


pApplicationUser :: Parser ApplicationUser
pApplicationUser =
    ApplicationUser <$> pUsername <*> pPassword
  where
    pUsername :: Parser Text
    pUsername =
      Opt.strOption
        (  Opt.long "username"
        <> Opt.help "The name of the user."
        )

    pPassword :: Parser Text
    pPassword =
      Opt.strOption
        (  Opt.long "password"
        <> Opt.help "The password of the user."
        )


pPoolId :: Parser PoolId
pPoolId =
  PoolId <$> Opt.strOption
    (  Opt.long "poolId"
    <> Opt.help "The pool id of the operator, the hash of the 'cold' pool key."
    )

pFilePath :: Parser FilePath
pFilePath =
  Opt.strOption
    (  Opt.long "metadata"
    <> Opt.help "The JSON metadata filepath location."
    <> Opt.metavar "FILEPATH"
    <> Opt.completer (Opt.bashCompleter "directory")
    )

pPoolHash :: Parser PoolMetadataHash
pPoolHash =
  PoolMetadataHash <$> Opt.strOption
    (  Opt.long "poolhash"
    <> Opt.help "The JSON metadata Blake2 256 hash."
    )

pSmashMigrationDir :: Parser MigrationDir
pSmashMigrationDir =
  MigrationDir <$> Opt.strOption
    (  Opt.long "mdir"
    <> Opt.help "The SMASH directory containing the migrations."
    <> Opt.completer (Opt.bashCompleter "directory")
    )

pLogFileDir :: Parser LogFileDir
pLogFileDir =
  LogFileDir <$> Opt.strOption
    (  Opt.long "ldir"
    <> Opt.help "The directory to write the log to."
    <> Opt.completer (Opt.bashCompleter "directory")
    )

pTickerName :: Parser Text
pTickerName =
  Opt.strOption
    (  Opt.long "tickerName"
    <> Opt.help "The name of the ticker."
    )

