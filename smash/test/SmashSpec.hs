{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module SmashSpec
    ( smashSpec
    ) where

import           Cardano.Prelude

import           Crypto.Sign.Ed25519     (createKeypair)

import           Test.Hspec              (Spec, describe)
import           Test.Hspec.QuickCheck   (prop)

import           Test.QuickCheck         (Arbitrary (..), Gen, elements, listOf)
import           Test.QuickCheck.Monadic (assert, monadicIO, run)

import           Cardano.SMASH.DB
import           Cardano.SMASH.Types

-- | Test spec for smash
smashSpec :: Spec
smashSpec = do

    describe "DataLayer" $ do
        describe "Delisted pool" $
            prop "adding a pool hash adds it to the data layer" $ monadicIO $ do

                (pk, _) <- run $ createKeypair

                let newPoolId :: PoolId
                    newPoolId = PoolId . show $ pk

                let delistedPoolId :: PoolId
                    delistedPoolId = PoolId $ getPoolId newPoolId

                dataLayer <- run createStubbedDataLayer

                let addDelistedPool = dlAddDelistedPool dataLayer
                newDelistedPoolState <- run $ addDelistedPool delistedPoolId

                let checkDelistedPool = dlCheckDelistedPool dataLayer
                isDelisted <- run $ checkDelistedPool delistedPoolId

                assert $ isRight newDelistedPoolState
                assert $ isDelisted

        describe "Fetch errors" $
            prop "adding a fetch error adds it to the data layer" $ \(blockNo) -> monadicIO $ do

                (pk, _) <- run $ createKeypair

                let newPoolId :: PoolId
                    newPoolId = PoolId . show $ pk

                dataLayer <- run createStubbedDataLayer

                let addRetiredPool = dlAddRetiredPool dataLayer
                retiredPoolId <- run $ addRetiredPool newPoolId blockNo

                let getRetiredPools = dlGetRetiredPools dataLayer
                retiredPoolsId <- run $ getRetiredPools

                assert $ isRight retiredPoolId
                assert $ isRight retiredPoolsId

                let retiredPoolIdE      = fromRight (PoolId "X") retiredPoolId
                let retiredPoolsIdE     = fromRight [] retiredPoolsId

                assert $ retiredPoolIdE `elem` retiredPoolsIdE


        describe "Pool metadata" $ do
            prop "adding a pool metadata and returning the same" $ \(poolOfflineMetadata) -> monadicIO $ do

                (pk, _) <- run $ createKeypair

                let newPoolId :: PoolId
                    newPoolId = PoolId . show $ pk

                let newPoolHash :: PoolMetadataHash
                    newPoolHash = PoolMetadataHash . show $ pk

                -- At some point we might switch to using actual pool metadata for testing
                --poolOfflineMetadata <- run $ readFile "./test_pool.json"

                let poolTicker :: PoolTicker
                    poolTicker = PoolTicker "TESTT"

                dataLayer <- run createStubbedDataLayer

                -- Maybe PoolMetadataReferenceId -> PoolId -> PoolMetadataHash -> Text -> PoolTicker -> IO (Either DBFail Text)
                let addPoolMetadata = dlAddPoolMetadata dataLayer
                newPoolOfflineMetadata  <- run $ addPoolMetadata Nothing newPoolId newPoolHash poolOfflineMetadata poolTicker

                let getPoolMetadata' = dlGetPoolMetadata dataLayer
                newPoolOfflineMetadata' <- run $ getPoolMetadata' newPoolId newPoolHash

                assert $ isRight newPoolOfflineMetadata
                assert $ isRight newPoolOfflineMetadata'

                --assert $ newPoolOfflineMetadata == newPoolOfflineMetadata'

            prop "query non-existing pool metadata" $ monadicIO $ do

                (pk, _)             <- run $ createKeypair

                let newPoolId :: PoolId
                    newPoolId = PoolId . show $ pk

                let newPoolHash :: PoolMetadataHash
                    newPoolHash = PoolMetadataHash . show $ pk

                dataLayer <- run createStubbedDataLayer

                let getPoolMetadata' = dlGetPoolMetadata dataLayer
                newPoolOfflineMetadata <- run $ getPoolMetadata' newPoolId newPoolHash

                -- This pool hash does not exist!
                assert $ isLeft newPoolOfflineMetadata


genSafeChar :: Gen Char
genSafeChar = elements ['a'..'z']

genSafeText :: Gen Text
genSafeText = toS <$> listOf genSafeChar

instance Arbitrary PoolMetadataRaw where
    arbitrary = PoolMetadataRaw <$> arbitrary

-- TODO(KS): Generate realistic @PoolId@ and @PoolMetadataHash@ values.

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

