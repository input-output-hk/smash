{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

module DB
    ( module X
    , DataLayer (..)
    , stubbedDataLayer
    , postgresqlDataLayer
    -- * Examples
    , stubbedInitialDataMap
    , stubbedBlacklistedPools
    ) where

import           Cardano.Prelude

import qualified Data.Map as Map
import           Data.IORef (IORef, readIORef, modifyIORef)

import           Types

import           Cardano.Db.Insert (insertPoolMetadata, insertBlacklistedPool)
import           Cardano.Db.Query (DBFail (..), queryPoolMetadata)

import           Cardano.Db.Migration as X
import           Cardano.Db.Migration.Version as X
import           Cardano.Db.PGConfig as X
import           Cardano.Db.Run as X
import           Cardano.Db.Query as X
import           Cardano.Db.Schema as X
import           Cardano.Db.Error as X

-- | This is the data layer for the DB.
-- The resulting operation has to be @IO@, it can be made more granular,
-- but currently there is no complexity involved for that to be a sane choice.
-- TODO(KS): Newtype wrapper around @Text@ for the metadata.
data DataLayer = DataLayer
    { dlGetPoolMetadata         :: PoolHash -> IO (Either DBFail Text)
    , dlAddPoolMetadata         :: PoolHash -> Text -> IO (Either DBFail Text)
    , dlCheckBlacklistedPool    :: BlacklistPoolHash -> IO Bool
    , dlAddBlacklistedPool      :: BlacklistPoolHash -> IO (Either DBFail BlacklistPoolHash)
    , dlGetAdminUsers           :: IO (Either DBFail [AdminUser])
    } deriving (Generic)

-- | Simple stubbed @DataLayer@ for an example.
-- We do need state here. _This is thread safe._
-- __This is really our model here.__
stubbedDataLayer
    :: IORef (Map PoolHash Text)
    -> IORef [PoolHash]
    -> DataLayer
stubbedDataLayer ioDataMap ioBlacklistedPool = DataLayer
    { dlGetPoolMetadata     = \poolHash -> do
        ioDataMap' <- readIORef ioDataMap
        case (Map.lookup poolHash ioDataMap') of
            Just poolOfflineMetadata'   -> return . Right $ poolOfflineMetadata'
            Nothing                     -> return $ Left (DbLookupPoolMetadataHash (encodeUtf8 $ getPoolHash poolHash))

    , dlAddPoolMetadata     = \poolHash poolMetadata -> do
        -- TODO(KS): What if the pool metadata already exists?
        _ <- modifyIORef ioDataMap (\dataMap -> Map.insert poolHash poolMetadata dataMap)
        return . Right $ poolMetadata

    , dlCheckBlacklistedPool = \blacklistedPool -> do
        let blacklistedPoolHash' = PoolHash $ blacklistPool blacklistedPool
        blacklistedPool' <- readIORef ioBlacklistedPool
        return $ blacklistedPoolHash' `elem` blacklistedPool'

    , dlAddBlacklistedPool  = \blacklistedPool -> do
        let blacklistedPoolHash' = PoolHash $ blacklistPool blacklistedPool
        _ <- modifyIORef ioBlacklistedPool (\pool -> [blacklistedPoolHash'] ++ pool)
        -- TODO(KS): Do I even need to query this?
        _blacklistedPool' <- readIORef ioBlacklistedPool
        return $ Right blacklistedPool

    , dlGetAdminUsers       = return $ Right []
    }

-- The approximation for the table.
stubbedInitialDataMap :: Map PoolHash Text
stubbedInitialDataMap = Map.fromList
    [ (createPoolHash "AAAAC3NzaC1lZDI1NTE5AAAAIKFx4CnxqX9mCaUeqp/4EI1+Ly9SfL23/Uxd0Ieegspc", show examplePoolOfflineMetadata)
    ]

-- The approximation for the table.
stubbedBlacklistedPools :: [PoolHash]
stubbedBlacklistedPools = []

postgresqlDataLayer :: DataLayer
postgresqlDataLayer = DataLayer
    { dlGetPoolMetadata = \poolHash -> do
        poolMetadata <- runDbAction Nothing $ queryPoolMetadata (encodeUtf8 $ getPoolHash poolHash)
        return (poolMetadataMetadata <$> poolMetadata)

    , dlAddPoolMetadata     = \poolHash poolMetadata -> do
        let poolHashBytestring = encodeUtf8 $ getPoolHash poolHash
        _ <- runDbAction Nothing $ insertPoolMetadata $ PoolMetadata poolHashBytestring poolMetadata
        return $ Right poolMetadata

    , dlCheckBlacklistedPool = \blacklistedPool -> do
        let blacklistPoolHash = encodeUtf8 $ blacklistPool blacklistedPool
        runDbAction Nothing $ queryBlacklistedPool blacklistPoolHash

    , dlAddBlacklistedPool  = \blacklistedPool -> do
        _ <- runDbAction Nothing $ insertBlacklistedPool $ BlacklistedPool $ encodeUtf8 $ blacklistPool blacklistedPool
        return $ Right blacklistedPool

    , dlGetAdminUsers       = do
        adminUsers <- runDbAction Nothing $ queryAdminUsers
        return $ Right adminUsers

    }

