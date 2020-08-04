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

import           Data.IORef                   (IORef, modifyIORef, readIORef)
import qualified Data.Map                     as Map

import           Types

import           Cardano.Db.Insert            (insertBlacklistedPool,
                                               insertPoolMetadata,
                                               insertPoolMetadataReference,
                                               insertReservedTicker)
import           Cardano.Db.Query             (DBFail (..), queryPoolMetadata)

import           Cardano.Db.Error             as X
import           Cardano.Db.Migration         as X
import           Cardano.Db.Migration.Version as X
import           Cardano.Db.PGConfig          as X
import           Cardano.Db.Query             as X
import           Cardano.Db.Run               as X
import           Cardano.Db.Schema            as X (AdminUser (..),
                                                    BlacklistedPool (..),
                                                    Block (..), Meta (..),
                                                    PoolMetadata (..),
                                                    PoolMetadataReference (..),
                                                    PoolMetadataReferenceId,
                                                    ReservedTicker (..),
                                                    ReservedTickerId (..),
                                                    poolMetadataMetadata)
import qualified Cardano.Db.Types             as Types

-- | This is the data layer for the DB.
-- The resulting operation has to be @IO@, it can be made more granular,
-- but currently there is no complexity involved for that to be a sane choice.
-- TODO(KS): Newtype wrapper around @Text@ for the metadata.
data DataLayer = DataLayer
    { dlGetPoolMetadata         :: PoolId -> PoolMetadataHash -> IO (Either DBFail (Text, Text))
    , dlAddPoolMetadata         :: PoolId -> PoolMetadataHash -> Text -> PoolTicker -> IO (Either DBFail Text)
    , dlAddMetaDataReference    :: PoolId -> PoolUrl -> PoolMetadataHash -> IO (Either DBFail PoolMetadataReferenceId)
    , dlAddReservedTicker       :: Text -> PoolMetadataHash -> IO (Either DBFail ReservedTickerId)
    , dlCheckReservedTicker     :: Text -> IO (Maybe ReservedTicker)
    , dlCheckBlacklistedPool    :: PoolId -> IO Bool
    , dlAddBlacklistedPool      :: PoolId -> IO (Either DBFail PoolId)
    , dlGetAdminUsers           :: IO (Either DBFail [AdminUser])
    } deriving (Generic)

-- | Simple stubbed @DataLayer@ for an example.
-- We do need state here. _This is thread safe._
-- __This is really our model here.__
stubbedDataLayer
    :: IORef (Map (PoolId, PoolMetadataHash) Text)
    -> IORef [PoolId]
    -> DataLayer
stubbedDataLayer ioDataMap ioBlacklistedPool = DataLayer
    { dlGetPoolMetadata     = \poolId poolmdHash -> do
        ioDataMap' <- readIORef ioDataMap
        case (Map.lookup (poolId, poolmdHash) ioDataMap') of
            Just poolOfflineMetadata'   -> return . Right $ ("Test", poolOfflineMetadata')
            Nothing                     -> return $ Left (DbLookupPoolMetadataHash poolId poolmdHash)

    , dlAddPoolMetadata     = \poolId poolmdHash poolMetadata poolTicker -> do
        -- TODO(KS): What if the pool metadata already exists?
        _ <- modifyIORef ioDataMap (Map.insert (poolId, poolmdHash) poolMetadata)
        return . Right $ poolMetadata

    , dlAddReservedTicker = \tickerName poolMetadataHash -> panic "!"

    , dlCheckReservedTicker = \tickerName -> panic "!"

    , dlAddMetaDataReference = \poolId poolUrl poolMetadataHash -> panic "!"

    , dlCheckBlacklistedPool = \poolId -> do
        blacklistedPool' <- readIORef ioBlacklistedPool
        return $ poolId `elem` blacklistedPool'

    , dlAddBlacklistedPool  = \poolId -> do
        _ <- modifyIORef ioBlacklistedPool (\pool -> [poolId] ++ pool)
        -- TODO(KS): Do I even need to query this?
        _blacklistedPool' <- readIORef ioBlacklistedPool
        return $ Right poolId

    , dlGetAdminUsers       = return $ Right []
    }

-- The approximation for the table.
stubbedInitialDataMap :: Map (PoolId, PoolMetadataHash) Text
stubbedInitialDataMap = Map.fromList
    [ ((PoolId "AAAAC3NzaC1lZDI1NTE5AAAAIKFx4CnxqX9mCaUeqp/4EI1+Ly9SfL23/Uxd0Ieegspc", PoolMetadataHash "HASH"), show examplePoolOfflineMetadata)
    ]

-- The approximation for the table.
stubbedBlacklistedPools :: [PoolId]
stubbedBlacklistedPools = []

postgresqlDataLayer :: DataLayer
postgresqlDataLayer = DataLayer
    { dlGetPoolMetadata = \poolId poolMetadataHash -> do
        poolMetadata <- runDbAction Nothing $ queryPoolMetadata poolId poolMetadataHash
        let poolTickerName = Types.getTickerName . poolMetadataTickerName <$> poolMetadata
        let poolMetadata' = Types.getPoolMetadata . poolMetadataMetadata <$> poolMetadata
        -- Ugh. Very sorry about this.
        return $ (,) <$> poolTickerName <*> poolMetadata'

    , dlAddPoolMetadata     = \poolId poolHash poolMetadata poolTicker -> do
        let poolTickerName = Types.TickerName $ getPoolTicker poolTicker
        _ <- runDbAction Nothing $ insertPoolMetadata $ PoolMetadata poolId poolTickerName poolHash (Types.PoolMetadataRaw poolMetadata)
        return $ Right poolMetadata

    , dlAddMetaDataReference = \poolId poolUrl poolMetadataHash -> do
        poolMetadataRefId <- runDbAction Nothing $ insertPoolMetadataReference $
            PoolMetadataReference
                { poolMetadataReferenceUrl = poolUrl
                , poolMetadataReferenceHash = poolMetadataHash
                , poolMetadataReferencePoolId = poolId
                }
        return $ Right poolMetadataRefId

    , dlAddReservedTicker = \tickerName poolMetadataHash -> do
        reservedTickerId <- runDbAction Nothing $ insertReservedTicker $ ReservedTicker tickerName poolMetadataHash
        return $ Right reservedTickerId

    , dlCheckReservedTicker = \tickerName ->
        runDbAction Nothing $ queryReservedTicker tickerName

    , dlCheckBlacklistedPool = \poolId -> do
        runDbAction Nothing $ queryBlacklistedPool poolId

    , dlAddBlacklistedPool  = \poolId -> do
        _ <- runDbAction Nothing $ insertBlacklistedPool $ BlacklistedPool poolId
        return $ Right poolId

    , dlGetAdminUsers       = do
        adminUsers <- runDbAction Nothing $ queryAdminUsers
        return $ Right adminUsers

    }

