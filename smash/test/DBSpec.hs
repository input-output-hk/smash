module Main where

import           Cardano.Prelude

import           System.Directory (getCurrentDirectory)
import           System.Environment (lookupEnv, setEnv)
import           System.FilePath ((</>))

import           Test.Hspec (describe, hspec)

import           MigrationSpec (migrationSpec)

-- | Entry point for tests.
main :: IO ()
main = do

    -- If the env is not set, set it to default.
    mPgPassFile <- lookupEnv "SMASHPGPASSFILE"
    when (isNothing mPgPassFile) $ do
        currentDir <- getCurrentDirectory
        setEnv "SMASHPGPASSFILE" (currentDir </> "../config/pgpass-test")

    hspec $ do
        describe "Migration tests" migrationSpec

