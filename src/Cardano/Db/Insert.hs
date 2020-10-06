{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}

module Cardano.Db.Insert
  ( insertBlock
  , insertMeta
  , insertPoolMetadata
  , insertPoolMetadataReference
  , insertReservedTicker
  , insertDelistedPool
  , insertRetiredPool
  , insertAdminUser
  , insertPoolMetadataFetchError

  -- Export mainly for testing.
  , insertByReturnKey
  ) where

import           Cardano.Prelude hiding (Meta)

import           Control.Monad.IO.Class (MonadIO)
import           Control.Monad.Trans.Reader (ReaderT)

import           Database.Persist.Class (AtLeastOneUniqueKey, Key, PersistEntityBackend,
                    getByValue, insert, checkUnique)
import           Database.Persist.Sql (SqlBackend)
import           Database.Persist.Types (entityKey)

import           Cardano.Db.Schema
import           Cardano.Db.Error

insertBlock :: (MonadIO m) => Block -> ReaderT SqlBackend m BlockId
insertBlock = insertByReturnKey

insertMeta :: (MonadIO m) => Meta -> ReaderT SqlBackend m MetaId
insertMeta = insertByReturnKey

insertPoolMetadata :: (MonadIO m) => PoolMetadata -> ReaderT SqlBackend m PoolMetadataId
insertPoolMetadata = insertByReturnKey

insertPoolMetadataReference
    :: MonadIO m
    => PoolMetadataReference
    -> ReaderT SqlBackend m PoolMetadataReferenceId
insertPoolMetadataReference = insertByReturnKey

insertReservedTicker :: (MonadIO m) => ReservedTicker -> ReaderT SqlBackend m (Either DBFail ReservedTickerId)
insertReservedTicker reservedTicker = do
    isUnique <- checkUnique reservedTicker
    -- If there is no unique constraint violated, insert, otherwise return error.
    case isUnique of
        Nothing -> Right <$> insertByReturnKey reservedTicker
        Just _key -> return . Left . ReservedTickerAlreadyInserted $ reservedTickerName reservedTicker

insertDelistedPool :: (MonadIO m) => DelistedPool -> ReaderT SqlBackend m DelistedPoolId
insertDelistedPool = insertByReturnKey

insertRetiredPool :: (MonadIO m) => RetiredPool -> ReaderT SqlBackend m RetiredPoolId
insertRetiredPool = insertByReturnKey

insertAdminUser :: (MonadIO m) => AdminUser -> ReaderT SqlBackend m AdminUserId
insertAdminUser = insertByReturnKey

insertPoolMetadataFetchError
    :: (MonadIO m)
    => PoolMetadataFetchError
    -> ReaderT SqlBackend m PoolMetadataFetchErrorId
insertPoolMetadataFetchError = insertByReturnKey

-------------------------------------------------------------------------------

-- | Insert a record (with a Unique constraint), and return 'Right key' if the
-- record is inserted and 'Left key' if the record already exists in the DB.
insertByReturnKey
    :: ( AtLeastOneUniqueKey record
       , MonadIO m
       , PersistEntityBackend record ~ SqlBackend
       )
    => record -> ReaderT SqlBackend m (Key record)
insertByReturnKey value = do
  res <- getByValue value
  case res of
    Nothing -> insert value
    Just r -> pure $ entityKey r

