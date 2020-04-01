{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

module DB
    ( DataLayerError
    , DataLayer (..)
    , stubbedDataLayer
    -- * Examples
    , stubbedInitialDataMap
    , stubbedBlacklistedPools
    ) where

import           Cardano.Prelude

import qualified Data.Map as Map
import           Data.IORef (IORef, readIORef, modifyIORef)

import           Types

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
-- We do need state here. _This thing is thread safe._
-- __This is really our model here.__
stubbedDataLayer
    :: IORef (Map PoolHash PoolOfflineMetadata)
    -> IORef [PoolHash]
    -> DataLayer
stubbedDataLayer ioDataMap ioBlacklistedPool = DataLayer
    { dlGetPoolMetadata     = \poolHash -> do
        ioDataMap' <- readIORef ioDataMap
        case (Map.lookup poolHash ioDataMap') of
            Just poolOfflineMetadata'   -> return $ Right poolOfflineMetadata'
            Nothing                     -> return $ Left (PoolHashNotFound poolHash)

    , dlAddPoolMetadata     = \poolHash poolMetadata -> do
        -- TODO(KS): What if the pool metadata already exists?
        _ <- modifyIORef ioDataMap (\dataMap -> Map.insert poolHash poolMetadata dataMap)
        return $ Right poolMetadata

    , dlGetBlacklistedPools = do
        blacklistedPool <- readIORef ioBlacklistedPool
        return $ Right blacklistedPool

    , dlAddBlacklistedPool  = \poolHash -> do
        _ <- modifyIORef ioBlacklistedPool (\pool -> [poolHash] ++ pool)
        -- TODO(KS): Do I even need to query this?
        blacklistedPool <- readIORef ioBlacklistedPool
        return $ Right poolHash

    }

-- The approximation for the table.
stubbedInitialDataMap :: Map PoolHash PoolOfflineMetadata
stubbedInitialDataMap = Map.fromList
    [ (createPoolHash "AAAAC3NzaC1lZDI1NTE5AAAAIKFx4CnxqX9mCaUeqp/4EI1+Ly9SfL23/Uxd0Ieegspc", examplePoolOfflineMetadata)
    ]

-- The approximation for the table.
stubbedBlacklistedPools :: [PoolHash]
stubbedBlacklistedPools = []

