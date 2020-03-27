{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

module DB
    ( Configuration (..)
    , stubbedConfiguration
    , DataLayerError
    , DataLayer
    , stubbedDataLayer
    ) where

import           Cardano.Prelude

import qualified Data.Map as Map

import           Types

-- | The basic @Configuration@.
data Configuration = Configuration
    { cPortNumber :: !Word
    } deriving (Eq, Show)

stubbedConfiguration :: Configuration
stubbedConfiguration = Configuration 3100

-- | Errors, not exceptions.
data DataLayerError
    = PoolHashNotFound !PoolHash
    deriving (Eq, Show)

-- | This is the data layer for the DB.
-- The resulting operation has to be @IO@, it can be made more granular,
-- but currently there is no complexity involved for that to be a sane choice.
data DataLayer = DataLayer
    { dlGetPoolMetadata     :: PoolHash -> IO (Either DataLayerError PoolOfflineMetadata)
    , dlAddPoolMetadata     :: PoolHash -> PoolOfflineMetadata -> IO (Either DataLayerError PoolOfflineMetadata)
    , dlGetBlacklistedPools :: IO (Either DataLayerError [PoolHash])
    , dlAddBlacklistedPool  :: PoolHash -> IO (Either DataLayerError PoolHash)
    }

-- | Simple stubbed @DataLayer@ for an example.
-- We do need state here.
stubbedDataLayer :: DataLayer
stubbedDataLayer = DataLayer
    { dlGetPoolMetadata     = \poolHash ->
        case (Map.lookup poolHash stubbedInitialDataMap) of
            Just poolHash'  -> return $ Right poolHash'
            Nothing         -> return $ Left (PoolHashNotFound poolHash)

    , dlAddPoolMetadata     = \poolHash poolMetadata -> return $ Right poolMetadata -- Right $ Map.insert poolHash poolMetadata stubbedInitialDataMap
    , dlGetBlacklistedPools = return $ Right blacklistedPools
    , dlAddBlacklistedPool  = \poolHash -> return $ Right poolHash
    }

-- The approximation for the table.
stubbedInitialDataMap :: Map PoolHash PoolOfflineMetadata
stubbedInitialDataMap = Map.fromList
    [ (createPoolHash "AAAAC3NzaC1lZDI1NTE5AAAAIKFx4CnxqX9mCaUeqp/4EI1+Ly9SfL23/Uxd0Ieegspc", examplePoolOfflineMetadata)
    ]

-- The approximation for the table.
blacklistedPools :: [PoolHash]
blacklistedPools = []

