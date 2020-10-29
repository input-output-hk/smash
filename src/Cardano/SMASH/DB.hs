{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

module Cardano.SMASH.DB
    ( module X
    , DataLayer (..)
    , stubbedDataLayer
    , createStubbedDataLayer
    , postgresqlDataLayer
    -- * Examples
    , DelistedPoolsIORef (..)
    , RetiredPoolsIORef (..)
    , stubbedInitialDataMap
    , stubbedDelistedPools
    , stubbedRetiredPools
    ) where

import           Cardano.Prelude

import           Data.IORef                                (IORef, modifyIORef,
                                                            newIORef, readIORef)
import qualified Data.Map                                  as Map
import           Data.Time.Clock                           (UTCTime)
import           Data.Time.Clock.POSIX                     (utcTimeToPOSIXSeconds)

import           Cardano.SMASH.Types

import           Cardano.SMASH.DBSync.Db.Delete            (deleteDelistedPool)
import           Cardano.SMASH.DBSync.Db.Insert            (insertDelistedPool,
                                                            insertPoolMetadata,
                                                            insertPoolMetadataFetchError,
                                                            insertPoolMetadataReference,
                                                            insertReservedTicker,
                                                            insertRetiredPool)
import           Cardano.SMASH.DBSync.Db.Query             (DBFail (..),
                                                            queryPoolMetadata)

import           Cardano.SMASH.DBSync.Db.Error             as X
import           Cardano.SMASH.DBSync.Db.Migration         as X
import           Cardano.SMASH.DBSync.Db.Migration.Version as X
import           Cardano.SMASH.DBSync.Db.PGConfig          as X
import           Cardano.SMASH.DBSync.Db.Query             as X
import           Cardano.SMASH.DBSync.Db.Run               as X
import           Cardano.SMASH.DBSync.Db.Schema            as X (AdminUser (..),
                                                                 Block (..),
                                                                 DelistedPool (..),
                                                                 Meta (..),
                                                                 PoolMetadata (..),
                                                                 PoolMetadataFetchError (..),
                                                                 PoolMetadataFetchErrorId,
                                                                 PoolMetadataReference (..),
                                                                 PoolMetadataReferenceId,
                                                                 ReservedTicker (..),
                                                                 ReservedTickerId (..),
                                                                 RetiredPool (..),
                                                                 poolMetadataMetadata)
import qualified Cardano.SMASH.DBSync.Db.Types             as Types

-- | This is the data layer for the DB.
-- The resulting operation has to be @IO@, it can be made more granular,
-- but currently there is no complexity involved for that to be a sane choice.
-- TODO(KS): Newtype wrapper around @Text@ for the metadata.
data DataLayer = DataLayer
    { dlGetPoolMetadata         :: PoolId -> PoolMetadataHash -> IO (Either DBFail (Text, Text))
    , dlAddPoolMetadata         :: Maybe PoolMetadataReferenceId -> PoolId -> PoolMetadataHash -> Text -> PoolTicker -> IO (Either DBFail Text)

    , dlAddMetaDataReference    :: PoolId -> PoolUrl -> PoolMetadataHash -> IO PoolMetadataReferenceId

    , dlAddReservedTicker       :: Text -> PoolMetadataHash -> IO (Either DBFail ReservedTickerId)
    , dlCheckReservedTicker     :: Text -> IO (Maybe ReservedTicker)

    , dlGetDelistedPools        :: IO [PoolId]
    , dlCheckDelistedPool       :: PoolId -> IO Bool
    , dlAddDelistedPool         :: PoolId -> IO (Either DBFail PoolId)
    , dlRemoveDelistedPool      :: PoolId -> IO (Either DBFail PoolId)

    , dlAddRetiredPool          :: PoolId -> IO (Either DBFail PoolId)
    , dlGetRetiredPools         :: IO (Either DBFail [PoolId])

    , dlGetAdminUsers           :: IO (Either DBFail [AdminUser])

    -- TODO(KS): Switch to PoolFetchError!
    , dlAddFetchError           :: PoolMetadataFetchError -> IO (Either DBFail PoolMetadataFetchErrorId)
    , dlGetFetchErrors          :: PoolId -> Maybe UTCTime -> IO (Either DBFail [PoolFetchError])
    } deriving (Generic)

newtype DelistedPoolsIORef = DelistedPoolsIORef (IORef [PoolId])
    deriving (Eq)

newtype RetiredPoolsIORef = RetiredPoolsIORef (IORef [PoolId])
    deriving (Eq)

-- | Simple stubbed @DataLayer@ for an example.
-- We do need state here. _This is thread safe._
-- __This is really our model here.__
stubbedDataLayer
    :: IORef (Map (PoolId, PoolMetadataHash) (Text, Text))
    -> DelistedPoolsIORef
    -> RetiredPoolsIORef
    -> DataLayer
stubbedDataLayer ioDataMap (DelistedPoolsIORef ioDelistedPool) (RetiredPoolsIORef ioRetiredPools) = DataLayer
    { dlGetPoolMetadata     = \poolId poolmdHash -> do
        ioDataMap' <- readIORef ioDataMap
        case (Map.lookup (poolId, poolmdHash) ioDataMap') of
            Just (poolTicker', poolOfflineMetadata')
              -> return . Right $ (poolTicker', poolOfflineMetadata')
            Nothing                     -> return $ Left (DbLookupPoolMetadataHash poolId poolmdHash)
    , dlAddPoolMetadata     = \ _ poolId poolmdHash poolMetadata poolTicker -> do
        -- TODO(KS): What if the pool metadata already exists?
        _ <- modifyIORef ioDataMap (Map.insert (poolId, poolmdHash)
          (getPoolTicker poolTicker, poolMetadata))
        return . Right $ poolMetadata

    , dlAddMetaDataReference = \poolId poolUrl poolMetadataHash -> panic "!"

    , dlAddReservedTicker = \tickerName poolMetadataHash -> panic "!"
    , dlCheckReservedTicker = \tickerName -> pure Nothing

    , dlGetDelistedPools = readIORef ioDelistedPool
    , dlCheckDelistedPool = \poolId -> do
        blacklistedPool' <- readIORef ioDelistedPool
        return $ poolId `elem` blacklistedPool'
    , dlAddDelistedPool  = \poolId -> do
        _ <- modifyIORef ioDelistedPool (\pools -> [poolId] ++ pools)
        return $ Right poolId
    , dlRemoveDelistedPool = \poolId -> do
        _ <- modifyIORef ioDelistedPool (\pools -> filter (/= poolId) pools)
        return $ Right poolId

    , dlAddRetiredPool      = \poolId -> do
        _ <- modifyIORef ioRetiredPools (\pools -> [poolId] ++ pools)
        return . Right $ poolId
    , dlGetRetiredPools     = Right <$> readIORef ioRetiredPools

    , dlGetAdminUsers       = return $ Right []

    , dlAddFetchError       = \_ -> panic "!"
    , dlGetFetchErrors      = \_ -> panic "!"
    }

-- The approximation for the table.
stubbedInitialDataMap :: IO (IORef (Map (PoolId, PoolMetadataHash) (Text, Text)))
stubbedInitialDataMap = newIORef $ Map.fromList
    [ ((PoolId "AAAAC3NzaC1lZDI1NTE5AAAAIKFx4CnxqX9mCaUeqp/4EI1+Ly9SfL23/Uxd0Ieegspc", PoolMetadataHash "HASH"), ("Test", show examplePoolOfflineMetadata))
    ]

-- The approximation for the table.
stubbedDelistedPools :: IO DelistedPoolsIORef
stubbedDelistedPools = DelistedPoolsIORef <$> newIORef []

-- The approximation for the table.
stubbedRetiredPools :: IO RetiredPoolsIORef
stubbedRetiredPools = RetiredPoolsIORef <$> newIORef []

-- Init the data layer with the in-memory stubs.
createStubbedDataLayer :: IO DataLayer
createStubbedDataLayer = do

    ioDataMap        <- stubbedInitialDataMap
    ioDelistedPools  <- stubbedDelistedPools
    ioRetiredPools   <- stubbedRetiredPools

    let dataLayer :: DataLayer
        dataLayer = stubbedDataLayer ioDataMap ioDelistedPools ioRetiredPools

    return dataLayer

postgresqlDataLayer :: DataLayer
postgresqlDataLayer = DataLayer
    { dlGetPoolMetadata = \poolId poolMetadataHash -> do
        poolMetadata <- runDbAction Nothing $ queryPoolMetadata poolId poolMetadataHash
        let poolTickerName = Types.getTickerName . poolMetadataTickerName <$> poolMetadata
        let poolMetadata' = Types.getPoolMetadata . poolMetadataMetadata <$> poolMetadata
        return $ (,) <$> poolTickerName <*> poolMetadata'
    , dlAddPoolMetadata     = \mRefId poolId poolHash poolMetadata poolTicker -> do
        let poolTickerName = Types.TickerName $ getPoolTicker poolTicker
        _ <- runDbAction Nothing $ insertPoolMetadata $ PoolMetadata poolId poolTickerName poolHash (Types.PoolMetadataRaw poolMetadata) mRefId
        return $ Right poolMetadata

    , dlAddMetaDataReference = \poolId poolUrl poolMetadataHash -> do
        poolMetadataRefId <- runDbAction Nothing $ insertPoolMetadataReference $
            PoolMetadataReference
                { poolMetadataReferenceUrl = poolUrl
                , poolMetadataReferenceHash = poolMetadataHash
                , poolMetadataReferencePoolId = poolId
                }
        return poolMetadataRefId

    , dlAddReservedTicker = \tickerName poolMetadataHash ->
        runDbAction Nothing $ insertReservedTicker $ ReservedTicker tickerName poolMetadataHash
    , dlCheckReservedTicker = \tickerName ->
        runDbAction Nothing $ queryReservedTicker tickerName

    , dlGetDelistedPools = do
        delistedPoolsDB <- runDbAction Nothing queryAllDelistedPools
        -- Convert from DB-specific type to the "general" type
        return $ map (\delistedPoolDB -> PoolId . getPoolId $ delistedPoolPoolId delistedPoolDB) delistedPoolsDB
    , dlCheckDelistedPool = \poolId -> do
        runDbAction Nothing $ queryDelistedPool poolId
    , dlAddDelistedPool  = \poolId -> do
        delistedPoolId <- runDbAction Nothing $ insertDelistedPool $ DelistedPool poolId
        return $ Right poolId
    , dlRemoveDelistedPool = \poolId -> do
        isDeleted <- runDbAction Nothing $ deleteDelistedPool poolId
        -- Up for a discussion, but this might be more sensible in the lower DB layer.
        if isDeleted
            then return $ Right poolId
            else return $ Left RecordDoesNotExist

    , dlAddRetiredPool  = \poolId -> do
        _retiredPoolId <- runDbAction Nothing $ insertRetiredPool $ RetiredPool poolId
        return $ Right poolId
    , dlGetRetiredPools = do
        retiredPools <- runDbAction Nothing $ queryAllRetiredPools
        return $ Right $ map retiredPoolPoolId retiredPools

    , dlGetAdminUsers       = do
        adminUsers <- runDbAction Nothing $ queryAdminUsers
        return $ Right adminUsers

    , dlAddFetchError       = \poolMetadataFetchError -> do
        poolMetadataFetchErrorId <- runDbAction Nothing $ insertPoolMetadataFetchError poolMetadataFetchError
        return $ Right poolMetadataFetchErrorId
    , dlGetFetchErrors      = \poolId mTimeFrom -> do
        poolMetadataFetchErrors <- runDbAction Nothing (queryPoolMetadataFetchErrorByTime poolId mTimeFrom)
        pure $ sequence $ Right <$> map convertPoolMetadataFetchError poolMetadataFetchErrors
    }

convertPoolMetadataFetchError :: PoolMetadataFetchError -> PoolFetchError
convertPoolMetadataFetchError (PoolMetadataFetchError timeUTC poolId poolHash _pMRId fetchError retryCount) =
    PoolFetchError (utcTimeToPOSIXSeconds timeUTC) poolId poolHash fetchError retryCount

