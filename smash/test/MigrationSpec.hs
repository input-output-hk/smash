{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module MigrationSpec
    ( migrationSpec
    ) where

import           Cardano.Prelude

import           Control.Monad.Trans.Except.Extra  (left)
import           Data.Time.Clock.POSIX             (getPOSIXTime)

import           Test.Hspec                        (Spec, describe)
import           Test.Hspec.QuickCheck             (modifyMaxSuccess, prop)
import           Test.QuickCheck.Monadic           (assert, monadicIO, run)

import qualified Cardano.BM.Trace                  as Logging

import           Cardano.SMASH.FetchQueue
import           Cardano.SMASH.Offline
import           Cardano.SMASH.Types

import           Cardano.SMASH.DB
import           Cardano.SMASH.DBSync.Db.Insert    (insertPoolMetadataReference)
import           Cardano.SMASH.DBSync.Db.Migration (SmashLogFileDir (..),
                                                    SmashMigrationDir (..),
                                                    runMigrations)
import           Cardano.SMASH.DBSync.Db.Query     (querySchemaVersion)
import           Cardano.SMASH.DBSync.Db.Run       (runDbNoLogging)
import           Cardano.SMASH.DBSync.Db.Schema    (PoolMetadataReference (..),
                                                    SchemaVersion (..))

-- | Test spec for smash
-- SMASHPGPASSFILE=config/pgpass-test ./scripts/postgresql-setup.sh --createdb
migrationSpec :: Spec
migrationSpec = do
    describe "MigrationSpec" $ do
        modifyMaxSuccess (const 10) $ prop "migrations should be run without any issues" $ monadicIO $ do
            _ <- run migrationTest
            assert True

    describe "FetchQueueSpec" $ do
        describe "Retry count" $
            prop "retrying again increases the retry count" $ \(initialCount :: Word) -> monadicIO $ do

                -- Probably switch to @DataLayer@
                poolMetadataRefIdE <- run $ runDbNoLogging $ insertPoolMetadataReference $ PoolMetadataReference (PoolId "1") (PoolUrl "http://test.com") (PoolMetadataHash "hash")

                poolMetadataRefId <-    case poolMetadataRefIdE of
                                            Left err -> panic $ show err
                                            Right id -> return id

                timeNow <- run $ getPOSIXTime --secondsToNominalDiffTime timeNowInt

                let retry =
                        Retry
                            { fetchTime = timeNow
                            , retryTime = timeNow + 60
                            , retryCount = initialCount
                            }

                let poolFetchRetry =
                        PoolFetchRetry
                            { pfrReferenceId = poolMetadataRefId
                            , pfrPoolIdWtf   = PoolId "1"
                            , pfrPoolUrl     = PoolUrl "http://test.com"
                            , pfrPoolMDHash  = PoolMetadataHash "hash"
                            , pfrRetry       = retry
                            }

                let dataLayer = postgresqlDataLayer

                let fetchInsert = \_ _ _ -> left $ FEIOException "Dunno"

                --print $ showRetryTimes (pfrRetry poolFetchRetry)

                poolFetchRetry <- run $ fetchInsertNewPoolMetadataOld dataLayer Logging.nullTracer fetchInsert poolFetchRetry
                --print $ showRetryTimes (pfrRetry poolFetchRetry)

                poolFetchRetry <- run $ fetchInsertNewPoolMetadataOld dataLayer Logging.nullTracer fetchInsert poolFetchRetry
                --print $ showRetryTimes (pfrRetry poolFetchRetry)

                poolFetchRetry <- run $ fetchInsertNewPoolMetadataOld dataLayer Logging.nullTracer fetchInsert poolFetchRetry
                --print $ showRetryTimes (pfrRetry poolFetchRetry)

                let newRetryCount = retryCount (pfrRetry poolFetchRetry)

                assert $ newRetryCount == initialCount + 3


-- Really just make sure that the migrations do actually run correctly.
-- If they fail the file path of the log file (in /tmp) will be printed.
migrationTest :: IO ()
migrationTest = do
    let schemaDir = SmashMigrationDir "../schema"
    runMigrations Logging.nullTracer (\x -> x) schemaDir (Just $ SmashLogFileDir "/tmp")

    -- TODO(KS): This version HAS to be changed manually so we don't mess up the
    -- migration.
    let expected = SchemaVersion 1 5 0
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

