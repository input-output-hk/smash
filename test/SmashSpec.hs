{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SmashSpec
    ( smashSpec
    ) where

import           Cardano.Prelude

import           Crypto.Sign.Ed25519     (createKeypair)
import           Data.IORef              (IORef, newIORef)

import           Test.Hspec              (Spec, describe, it)
import           Test.Hspec.QuickCheck   (modifyMaxSuccess, prop)
import           Test.QuickCheck         (Arbitrary (..), Gen, Property,
                                          elements, generate, listOf)
import           Test.QuickCheck.Monadic (assert, monadicIO, run)

import           DB
import           Types

-- | Test spec for smash
smashSpec :: Spec
smashSpec = do
    describe "DataLayer" $ do
        describe "Blacklisted pool" $
            prop "adding a pool hash adds it to the data layer" $ monadicIO $ do

                (pk, _)             <- run $ createKeypair

                let newPoolHash :: PoolHash
                    newPoolHash = createPoolHash . show $ pk

                ioDataMap           <- run $ newIORef stubbedInitialDataMap
                ioBlacklistedPools  <- run $ newIORef stubbedBlacklistedPools

                let dataLayer :: DataLayer
                    dataLayer = stubbedDataLayer ioDataMap ioBlacklistedPools

                newBlacklistPoolState <- run $ (dlAddBlacklistedPool dataLayer) newPoolHash

                newBlacklistedPools   <- run $ dlGetBlacklistedPools dataLayer

                assert $ isRight newBlacklistPoolState
                assert $ isRight newBlacklistedPools

                assert $ newBlacklistedPools == Right (newPoolHash : stubbedBlacklistedPools)

        describe "Pool metadata" $ do
            prop "adding a pool metadata and returning the same" $ \(poolOfflineMetadata) -> monadicIO $ do

                (pk, _)             <- run $ createKeypair

                let newPoolHash :: PoolHash
                    newPoolHash = createPoolHash . show $ pk

                ioDataMap           <- run $ newIORef stubbedInitialDataMap
                ioBlacklistedPools  <- run $ newIORef stubbedBlacklistedPools

                let dataLayer :: DataLayer
                    dataLayer = stubbedDataLayer ioDataMap ioBlacklistedPools

                newPoolOfflineMetadata  <- run $ (dlAddPoolMetadata dataLayer) newPoolHash poolOfflineMetadata

                newPoolOfflineMetadata' <- run $ (dlGetPoolMetadata dataLayer) newPoolHash

                assert $ isRight newPoolOfflineMetadata
                assert $ isRight newPoolOfflineMetadata'

                assert $ newPoolOfflineMetadata == newPoolOfflineMetadata'

            prop "query non-existing pool metadata" $ monadicIO $ do

                (pk, _)             <- run $ createKeypair

                let newPoolHash :: PoolHash
                    newPoolHash = createPoolHash . show $ pk

                ioDataMap           <- run $ newIORef stubbedInitialDataMap
                ioBlacklistedPools  <- run $ newIORef stubbedBlacklistedPools

                let dataLayer :: DataLayer
                    dataLayer = stubbedDataLayer ioDataMap ioBlacklistedPools

                newPoolOfflineMetadata <- run $ (dlGetPoolMetadata dataLayer) newPoolHash

                -- This pool hash does not exist!
                assert $ isLeft newPoolOfflineMetadata


genSafeChar :: Gen Char
genSafeChar = elements ['a'..'z']

genSafeText :: Gen Text
genSafeText = toS <$> listOf genSafeChar

-- TODO(KS): Create more realistic arbitrary instance.
instance Arbitrary Text where
    arbitrary = genSafeText

instance Arbitrary PoolOfflineMetadata where
    arbitrary = do
        poolName        <- PoolName         <$> genSafeText
        poolDescription <- PoolDescription  <$> genSafeText
        poolTicker      <- PoolTicker       <$> genSafeText
        poolHomepage    <- PoolHomepage     <$> genSafeText

        return $ createPoolOfflineMetadata
            poolName
            poolDescription
            poolTicker
            poolHomepage

