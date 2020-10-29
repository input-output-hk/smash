module Main where

import           Cardano.Prelude

import           Test.Hspec (describe, hspec)

import           SmashSpec (smashSpec)
import           SmashSpecSM (smashSpecSM)

-- | Entry point for tests.
main :: IO ()
main = hspec $ do
    describe "SMASH tests" smashSpec
    describe "SMASH state machine tests" smashSpecSM

