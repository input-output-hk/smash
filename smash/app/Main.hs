{-# LANGUAGE CPP                   #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances  #-}

-- The db conversion.
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main where

import           Cardano.Prelude              hiding (Meta)


import qualified Cardano.SMASH.DB             as DB

import           Cardano.SMASH.Lib
import           Cardano.SMASH.Types

import           Cardano.SMASH.DBSync.Metrics (withMetricSetters)
import           Cardano.SMASH.DBSyncRun      (runCardanoSyncWithSmash,
                                               setupTraceFromConfig)

import           Cardano.Sync.Config
import           Cardano.Sync.Config.Types

import           Options.Applicative          (Parser, ParserInfo, ParserPrefs)
import qualified Options.Applicative          as Opt

import           System.FilePath              ((</>))

import           Cardano.Slotting.Slot        (SlotNo (..))


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
    RunApplicationWithDbSync dbSyncNodeParams -> do
        prometheusPort <- dncPrometheusPort <$> readSyncNodeConfig (enpConfigFile dbSyncNodeParams)

        withMetricSetters prometheusPort $ \metricsSetters ->
            runCardanoSyncWithSmash Nothing metricsSetters dbSyncNodeParams


doCreateMigration :: MigrationDir -> IO ()
doCreateMigration (MigrationDir mdir) = do
  mfp <- DB.createMigration . DB.SmashMigrationDir $ mdir
  case mfp of
    Nothing -> putTextLn "No migration needed."
    Just fp -> putTextLn $ toS ("New migration '" ++ fp ++ "' created.")


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

