module Main where

import           Cardano.Prelude

import           DB
import           DbSyncPlugin          (poolMetadataDbSyncNodePlugin)
import           Lib

import           Cardano.SmashDbSync   (ConfigFile (..), GenesisFile (..),
                                        SmashDbSyncNodeParams (..),
                                        SocketPath (..), runDbSyncNode)

import           Cardano.Slotting.Slot (SlotNo (..))

import           Control.Applicative   (optional)

import           Data.Monoid           ((<>))

import           Options.Applicative   (Parser, ParserInfo, ParserPrefs)
import qualified Options.Applicative   as Opt


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
  = CreateMigration SmashMigrationDir
  | RunMigrations SmashMigrationDir (Maybe SmashLogFileDir)
  | RunApplication
  | RunApplicationWithDbSync SmashDbSyncNodeParams
  | InsertPool FilePath Text

runCommand :: Command -> IO ()
runCommand cmd =
  case cmd of
    CreateMigration mdir -> doCreateMigration mdir
    RunMigrations mdir mldir -> runMigrations (\pgConfig -> pgConfig) False mdir mldir
    RunApplication -> runApp defaultConfiguration
    RunApplicationWithDbSync dbSyncNodeParams ->
        race_
            (runDbSyncNode poolMetadataDbSyncNodePlugin dbSyncNodeParams)
            (runApp defaultConfiguration)
    InsertPool poolMetadataJsonPath poolHash -> do
        putTextLn "Inserting pool metadata!"
        result <- runPoolInsertion poolMetadataJsonPath poolHash
        either
            (\err -> putTextLn $ "Error occured. " <> renderLookupFail err)
            (\_ -> putTextLn "Insertion completed!")
            result

doCreateMigration :: SmashMigrationDir -> IO ()
doCreateMigration mdir = do
  mfp <- createMigration mdir
  case mfp of
    Nothing -> putTextLn "No migration needed."
    Just fp -> putTextLn $ toS ("New migration '" ++ fp ++ "' created.")

-------------------------------------------------------------------------------

opts :: ParserInfo SmashDbSyncNodeParams
opts =
  Opt.info (pCommandLine <**> Opt.helper)
    ( Opt.fullDesc
    <> Opt.progDesc "Extended Cardano POstgreSQL sync node."
    )


pCommandLine :: Parser SmashDbSyncNodeParams
pCommandLine =
  SmashDbSyncNodeParams
    <$> pConfigFile
    <*> pGenesisFile
    <*> pSocketPath
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

pGenesisFile :: Parser GenesisFile
pGenesisFile =
  GenesisFile <$> Opt.strOption
    ( Opt.long "genesis-file"
    <> Opt.help "Path to the genesis JSON file"
    <> Opt.completer (Opt.bashCompleter "file")
    <> Opt.metavar "FILEPATH"
    )

pMigrationDir :: Parser SmashMigrationDir
pMigrationDir =
  SmashMigrationDir <$> Opt.strOption
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

pVersion :: Parser (a -> a)
pVersion =
  Opt.infoOption "cardano-db-tool version 0.1.0.0"
    (  Opt.long "version"
    <> Opt.short 'v'
    <> Opt.help "Print the version and exit"
    )

pCommand :: Parser Command
pCommand =
  Opt.subparser
    ( Opt.command "create-migration"
        ( Opt.info pCreateMigration
          $ Opt.progDesc "Create a database migration (only really used by devs)."
          )
    <> Opt.command "run-migrations"
        ( Opt.info pRunMigrations
          $ Opt.progDesc "Run the database migrations (which are idempotent)."
          )
    <> Opt.command "run-app"
        ( Opt.info pRunApp
          $ Opt.progDesc "Run the application that just serves the pool info."
          )
    <> Opt.command "run-app-with-db-sync"
        ( Opt.info pRunAppWithDbSync
          $ Opt.progDesc "Run the application that syncs up the pool info and serves it."
          )
    <> Opt.command "insert-pool"
        ( Opt.info pInsertPool
          $ Opt.progDesc "Inserts the pool into the database (utility)."
          )
    )
  where
    pCreateMigration :: Parser Command
    pCreateMigration =
      CreateMigration <$> pSmashMigrationDir

    pRunMigrations :: Parser Command
    pRunMigrations =
      RunMigrations <$> pSmashMigrationDir <*> optional pLogFileDir

    -- Empty right now but we might add some params over time. Like ports and stuff?
    pRunApp :: Parser Command
    pRunApp =
      pure RunApplication

    -- Empty right now but we might add some params over time. Like ports and stuff?
    pRunAppWithDbSync :: Parser Command
    pRunAppWithDbSync =
      RunApplicationWithDbSync <$> pCommandLine

    -- Empty right now but we might add some params over time.
    pInsertPool :: Parser Command
    pInsertPool =
      InsertPool <$> pFilePath <*> pPoolHash

pFilePath :: Parser FilePath
pFilePath =
  Opt.strOption
    (  Opt.long "metadata"
    <> Opt.help "The JSON metadata filepath location."
    <> Opt.metavar "FILEPATH"
    <> Opt.completer (Opt.bashCompleter "directory")
    )

pPoolHash :: Parser Text
pPoolHash =
  Opt.strOption
    (  Opt.long "poolhash"
    <> Opt.help "The JSON metadata Blake2 256 hash."
    )

pSmashMigrationDir :: Parser SmashMigrationDir
pSmashMigrationDir =
  SmashMigrationDir <$> Opt.strOption
    (  Opt.long "mdir"
    <> Opt.help "The SMASH directory containing the migrations."
    <> Opt.completer (Opt.bashCompleter "directory")
    )

pLogFileDir :: Parser SmashLogFileDir
pLogFileDir =
  SmashLogFileDir <$> Opt.strOption
    (  Opt.long "ldir"
    <> Opt.help "The directory to write the log to."
    <> Opt.completer (Opt.bashCompleter "directory")
    )

