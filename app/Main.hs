module Main where

import           Cardano.Prelude

import           Lib

import           DB

import           Control.Applicative (optional)

import           Data.Monoid ((<>))

import           Options.Applicative (Parser, ParserInfo, ParserPrefs)
import qualified Options.Applicative as Opt


main :: IO ()
main = do
    Opt.customExecParser p opts >>= runCommand
  where
    opts :: ParserInfo Command
    opts = Opt.info (Opt.helper <*> pVersion <*> pCommand)
      ( Opt.fullDesc
      <> Opt.header "SMASH - Manage the Stakepool Metadata Aggregation Server"
      )

    p :: ParserPrefs
    p = Opt.prefs Opt.showHelpOnEmpty

-- -----------------------------------------------------------------------------

data Command
  = CreateMigration MigrationDir
  | RunMigrations MigrationDir (Maybe LogFileDir)
  | RunApplication
  | InsertPool FilePath Text

runCommand :: Command -> IO ()
runCommand cmd =
  case cmd of
    CreateMigration mdir -> doCreateMigration mdir
    RunMigrations mdir mldir -> runMigrations (\pgConfig -> pgConfig) False mdir mldir
    RunApplication -> runApp defaultConfiguration
    InsertPool poolMetadataJsonPath poolHash -> do
        putTextLn "Inserting pool metadata!"
        result <- runPoolInsertion poolMetadataJsonPath poolHash
        either
            (\err -> putTextLn $ "Error occured. " <> renderLookupFail err)
            (\_ -> putTextLn "Insertion completed!")
            result

doCreateMigration :: MigrationDir -> IO ()
doCreateMigration mdir = do
  mfp <- createMigration mdir
  case mfp of
    Nothing -> putTextLn "No migration needed."
    Just fp -> putTextLn $ toS ("New migration '" ++ fp ++ "' created.")

-------------------------------------------------------------------------------

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
          $ Opt.progDesc "Run the actual application."
          )
    <> Opt.command "insert-pool"
        ( Opt.info pInsertPool
          $ Opt.progDesc "Inserts the pool into the database (utility)."
          )
    )
  where
    pCreateMigration :: Parser Command
    pCreateMigration =
      CreateMigration <$> pMigrationDir

    pRunMigrations :: Parser Command
    pRunMigrations =
      RunMigrations <$> pMigrationDir <*> optional pLogFileDir

    -- Empty right now but we might add some params over time. Like ports and stuff?
    pRunApp :: Parser Command
    pRunApp =
      pure RunApplication

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

pMigrationDir :: Parser MigrationDir
pMigrationDir =
  MigrationDir <$> Opt.strOption
    (  Opt.long "mdir"
    <> Opt.help "The directory containing the migrations."
    <> Opt.completer (Opt.bashCompleter "directory")
    )

pLogFileDir :: Parser LogFileDir
pLogFileDir =
  LogFileDir <$> Opt.strOption
    (  Opt.long "ldir"
    <> Opt.help "The directory to write the log to."
    <> Opt.completer (Opt.bashCompleter "directory")
    )

