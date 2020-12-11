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

import           Control.Monad.Trans.Except.Extra          (left, newExceptT)

import           Data.IORef                                (IORef, modifyIORef,
                                                            newIORef, readIORef)
import qualified Data.Map                                  as Map
import           Data.Time.Clock                           (UTCTime)
import           Data.Time.Clock.POSIX                     (utcTimeToPOSIXSeconds)

import           Cardano.Slotting.Slot                     (SlotNo)

import           Cardano.SMASH.DBSync.Db.Delete            (deleteAdminUser,
                                                            deleteDelistedPool)
import           Cardano.SMASH.DBSync.Db.Insert            (insertAdminUser,
                                                            insertBlock,
                                                            insertDelistedPool,
                                                            insertMeta,
                                                            insertPoolMetadata,
                                                            insertPoolMetadataFetchError,
                                                            insertPoolMetadataReference,
                                                            insertReservedTicker,
                                                            insertRetiredPool)
import           Cardano.SMASH.DBSync.Db.Query             (DBFail (..),
                                                            queryPoolMetadata)
import           Cardano.SMASH.Types

import           Cardano.SMASH.DBSync.Db.Error             as X
import           Cardano.SMASH.DBSync.Db.Migration         as X
import           Cardano.SMASH.DBSync.Db.Migration.Version as X
import           Cardano.SMASH.DBSync.Db.PGConfig          as X
import           Cardano.SMASH.DBSync.Db.Query             as X
import           Cardano.SMASH.DBSync.Db.Run               as X
import           Cardano.SMASH.DBSync.Db.Schema            as X (AdminUser (..),
                                                                 Block (..),
                                                                 BlockId,
                                                                 DelistedPool (..),
                                                                 Meta (..),
                                                                 MetaId,
                                                                 PoolMetadata (..),
                                                                 PoolMetadataFetchError (..),
                                                                 PoolMetadataFetchErrorId,
                                                                 PoolMetadataReference (..),
                                                                 PoolMetadataReferenceId,
                                                                 ReservedTicker (..),
                                                                 ReservedTickerId,
                                                                 RetiredPool (..),
                                                                 poolMetadataMetadata)
import           Cardano.SMASH.DBSync.Db.Types             (TickerName (..))

-- | This is the data layer for the DB.
-- The resulting operation has to be @IO@, it can be made more granular,
-- but currently there is no complexity involved for that to be a sane choice.
data DataLayer = DataLayer
    { dlGetPoolMetadata         :: PoolId -> PoolMetadataHash -> IO (Either DBFail (TickerName, PoolMetadataRaw))
    , dlAddPoolMetadata         :: Maybe PoolMetadataReferenceId -> PoolId -> PoolMetadataHash -> PoolMetadataRaw -> PoolTicker -> IO (Either DBFail PoolMetadataRaw)

    , dlAddMetaDataReference    :: PoolId -> PoolUrl -> PoolMetadataHash -> IO (Either DBFail PoolMetadataReferenceId)

    , dlAddReservedTicker       :: TickerName -> PoolMetadataHash -> IO (Either DBFail ReservedTickerId)
    , dlCheckReservedTicker     :: TickerName -> IO (Maybe ReservedTicker)

    , dlGetDelistedPools        :: IO [PoolId]
    , dlCheckDelistedPool       :: PoolId -> IO Bool
    , dlAddDelistedPool         :: PoolId -> IO (Either DBFail PoolId)
    , dlRemoveDelistedPool      :: PoolId -> IO (Either DBFail PoolId)

    , dlAddRetiredPool          :: PoolId -> IO (Either DBFail PoolId)
    , dlGetRetiredPools         :: IO (Either DBFail [PoolId])

    , dlGetAdminUsers           :: IO (Either DBFail [AdminUser])
    , dlAddAdminUser            :: ApplicationUser -> IO (Either DBFail AdminUser)
    , dlRemoveAdminUser         :: ApplicationUser -> IO (Either DBFail AdminUser)

    -- TODO(KS): Switch to PoolFetchError!
    , dlAddFetchError           :: PoolMetadataFetchError -> IO (Either DBFail PoolMetadataFetchErrorId)
    , dlGetFetchErrors          :: PoolId -> Maybe UTCTime -> IO (Either DBFail [PoolFetchError])

    , dlAddGenesisMetaBlock     :: X.Meta -> X.Block -> IO (Either DBFail (MetaId, BlockId))

    , dlGetSlotHash             :: SlotNo -> IO (Maybe (SlotNo, ByteString))

    } deriving (Generic)

newtype DelistedPoolsIORef = DelistedPoolsIORef (IORef [PoolId])
    deriving (Eq)

newtype RetiredPoolsIORef = RetiredPoolsIORef (IORef [PoolId])
    deriving (Eq)

-- | Simple stubbed @DataLayer@ for an example.
-- We do need state here. _This is thread safe._
-- __This is really our model here.__
stubbedDataLayer
    :: IORef (Map (PoolId, PoolMetadataHash) (TickerName, PoolMetadataRaw))
    -> DelistedPoolsIORef
    -> RetiredPoolsIORef
    -> DataLayer
stubbedDataLayer ioDataMap (DelistedPoolsIORef ioDelistedPool) (RetiredPoolsIORef ioRetiredPools) = DataLayer
    { dlGetPoolMetadata     = \poolId poolmdHash -> do
        ioDataMap' <- readIORef ioDataMap
        case (Map.lookup (poolId, poolmdHash) ioDataMap') of
            Just (poolTicker', poolOfflineMetadata') -> return . Right $ (poolTicker', poolOfflineMetadata')
            Nothing -> return $ Left (DbLookupPoolMetadataHash poolId poolmdHash)
    , dlAddPoolMetadata     = \ _ poolId poolmdHash poolMetadata poolTicker -> do
        -- TODO(KS): What if the pool metadata already exists?
        _ <- modifyIORef ioDataMap (Map.insert (poolId, poolmdHash) (TickerName $ getPoolTicker poolTicker, poolMetadata))
        return . Right $ poolMetadata

    , dlAddMetaDataReference = \_poolId _poolUrl _poolMetadataHash -> panic "!"

    , dlAddReservedTicker = \_tickerName _poolMetadataHash -> panic "!"
    , dlCheckReservedTicker = \_tickerName -> pure Nothing

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
    , dlAddAdminUser        = \_ -> panic "!"
    , dlRemoveAdminUser     = \_ -> panic "!"

    , dlAddFetchError       = \_ -> panic "!"
    , dlGetFetchErrors      = \_ -> panic "!"

    , dlAddGenesisMetaBlock = \_ _ -> panic "!"

    , dlGetSlotHash         = \_ -> panic "!"
    }

-- The approximation for the table.
stubbedInitialDataMap :: IO (IORef (Map (PoolId, PoolMetadataHash) (TickerName, PoolMetadataRaw)))
stubbedInitialDataMap = newIORef $ Map.fromList
    [ ((PoolId "AAAAC3NzaC1lZDI1NTE5AAAAIKFx4CnxqX9mCaUeqp/4EI1+Ly9SfL23/Uxd0Ieegspc", PoolMetadataHash "HASH"), (TickerName "Test", PoolMetadataRaw $ show examplePoolOfflineMetadata))
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

-- TODO(KS): Passing the optional tracer.
postgresqlDataLayer :: DataLayer
postgresqlDataLayer = DataLayer
    { dlGetPoolMetadata = \poolId poolMetadataHash' -> do
        poolMetadata <- runDbAction Nothing $ queryPoolMetadata poolId poolMetadataHash'
        let poolTickerName = poolMetadataTickerName <$> poolMetadata
        let poolMetadata' = poolMetadataMetadata <$> poolMetadata
        return $ (,) <$> poolTickerName <*> poolMetadata'
    , dlAddPoolMetadata     = \mRefId poolId poolHash poolMetadata poolTicker -> do
        let poolTickerName = TickerName $ getPoolTicker poolTicker
        poolMetadataId <- runDbAction Nothing $ insertPoolMetadata $ PoolMetadata poolId poolTickerName poolHash poolMetadata mRefId

        case poolMetadataId of
            Left err  -> return $ Left err
            Right _id -> return $ Right poolMetadata

    , dlAddMetaDataReference = \poolId poolUrl poolMetadataHash' -> do
        poolMetadataRefId <- runDbAction Nothing $ insertPoolMetadataReference $
            PoolMetadataReference
                { poolMetadataReferenceUrl = poolUrl
                , poolMetadataReferenceHash = poolMetadataHash'
                , poolMetadataReferencePoolId = poolId
                }
        return poolMetadataRefId

    , dlAddReservedTicker = \tickerName poolMetadataHash' ->
        runDbAction Nothing $ insertReservedTicker $ ReservedTicker tickerName poolMetadataHash'
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

        case delistedPoolId of
            Left err  -> return $ Left err
            Right _id -> return $ Right poolId
    , dlRemoveDelistedPool = \poolId -> do
        isDeleted <- runDbAction Nothing $ deleteDelistedPool poolId
        -- Up for a discussion, but this might be more sensible in the lower DB layer.
        if isDeleted
            then return $ Right poolId
            else return $ Left RecordDoesNotExist

    , dlAddRetiredPool  = \poolId -> do
        retiredPoolId <- runDbAction Nothing $ insertRetiredPool $ RetiredPool poolId

        case retiredPoolId of
            Left err  -> return $ Left err
            Right _id -> return $ Right poolId
    , dlGetRetiredPools = do
        retiredPools <- runDbAction Nothing $ queryAllRetiredPools
        return $ Right $ map retiredPoolPoolId retiredPools

    , dlGetAdminUsers       = do
        adminUsers <- runDbAction Nothing $ queryAdminUsers
        return $ Right adminUsers
    , dlAddAdminUser        = \(ApplicationUser user pass') -> do
        let adminUser = AdminUser user pass'
        adminUserId <- runDbAction Nothing $ insertAdminUser adminUser
        case adminUserId of
            Left err  -> return $ Left err
            Right _id -> return $ Right adminUser
    , dlRemoveAdminUser     = \(ApplicationUser user pass') -> do
        let adminUser = AdminUser user pass'
        isDeleted <- runDbAction Nothing $ deleteAdminUser adminUser
        if isDeleted
            then return $ Right adminUser
            else return $ Left $ UnknownError "Admin user not deleted. Both username and password must match."

    , dlAddFetchError       = \poolMetadataFetchError -> do
        poolMetadataFetchErrorId <- runDbAction Nothing $ insertPoolMetadataFetchError poolMetadataFetchError
        return poolMetadataFetchErrorId
    , dlGetFetchErrors      = \poolId mTimeFrom -> do
        poolMetadataFetchErrors <- runDbAction Nothing (queryPoolMetadataFetchErrorByTime poolId mTimeFrom)
        pure $ sequence $ Right <$> map convertPoolMetadataFetchError poolMetadataFetchErrors

    , dlAddGenesisMetaBlock = \meta block -> do
        -- This whole function has to be atomic!
        runExceptT $ do
            -- Well, in theory this should be handled differently.
            count <- newExceptT (Right <$> (runDbAction Nothing $ queryBlockCount))

            when (count > 0) $
              left $ UnknownError "Shelley.insertValidateGenesisDist: Genesis data mismatch."

            metaId <- newExceptT $ runDbAction Nothing $ insertMeta $ meta
            blockId <- newExceptT $ runDbAction Nothing $ insertBlock $ block

            pure (metaId, blockId)

    , dlGetSlotHash = \slotNo ->
            runDbAction Nothing $ querySlotHash slotNo

    }

convertPoolMetadataFetchError :: PoolMetadataFetchError -> PoolFetchError
convertPoolMetadataFetchError (PoolMetadataFetchError timeUTC poolId poolHash _pMRId fetchError retryCount) =
    PoolFetchError (utcTimeToPOSIXSeconds timeUTC) poolId poolHash fetchError retryCount

