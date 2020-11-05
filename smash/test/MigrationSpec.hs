{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module MigrationSpec
    ( migrationSpec
    ) where

import           Cardano.Prelude

import           Test.Hspec                        (Spec, describe)
import           Test.Hspec.QuickCheck             (modifyMaxSuccess, prop)
import           Test.QuickCheck.Monadic           (assert, monadicIO, run)

import           Cardano.SMASH.DBSync.Db.Migration (SmashLogFileDir (..),
                                                    SmashMigrationDir (..),
                                                    runMigrations)
import           Cardano.SMASH.DBSync.Db.Query     (querySchemaVersion)
import           Cardano.SMASH.DBSync.Db.Run       (runDbNoLogging)
import           Cardano.SMASH.DBSync.Db.Schema    (SchemaVersion (..))

-- | Test spec for smash
-- SMASHPGPASSFILE=config/pgpass-test ./scripts/postgresql-setup.sh --createdb
migrationSpec :: Spec
migrationSpec = do
    describe "MigrationSpec" $ do
        modifyMaxSuccess (const 10) $ prop "migrations should be run without any issues" $ monadicIO $ do
            _ <- run migrationTest
            assert True

-- Really just make sure that the migrations do actually run correctly.
-- If they fail the file path of the log file (in /tmp) will be printed.
migrationTest :: IO ()
migrationTest = do
    let schemaDir = SmashMigrationDir "../schema"
    runMigrations (\x -> x) True schemaDir (Just $ SmashLogFileDir "/tmp")

    -- TODO(KS): This version HAS to be changed manually so we don't mess up the
    -- migration.
    let expected = SchemaVersion 1 4 0
    actual <- getDbSchemaVersion
    unless (expected == actual) $
        panic $ mconcat
              [ "Schema version mismatch. Expected "
              , showSchemaVersion expected
              , " but got "
              , showSchemaVersion actual
              , "."
              ]

getDbSchemaVersion :: IO SchemaVersion
getDbSchemaVersion =
  runDbNoLogging $
    fromMaybe (panic "getDbSchemaVersion: Nothing") <$> querySchemaVersion

showSchemaVersion :: SchemaVersion -> Text
showSchemaVersion (SchemaVersion a b c) =
    toS $ intercalate "." [show a, show b, show c]

