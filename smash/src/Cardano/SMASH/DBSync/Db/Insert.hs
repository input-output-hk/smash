{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies     #-}

module Cardano.SMASH.DBSync.Db.Insert
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

import           Cardano.Prelude                hiding (Meta)

import           Control.Monad.IO.Class         (MonadIO)
import           Control.Monad.Trans.Reader     (ReaderT, mapReaderT)

import           Database.Persist.Class         (AtLeastOneUniqueKey, Key,
                                                 PersistEntityBackend,
                                                 checkUnique, getByValue,
                                                 insert)
import           Database.Persist.Sql           (SqlBackend)
import           Database.Persist.Types         (entityKey)
import           Database.PostgreSQL.Simple     (SqlError)

import           Cardano.SMASH.DBSync.Db.Error
import           Cardano.SMASH.DBSync.Db.Schema

insertBlock :: (MonadIO m) => Block -> ReaderT SqlBackend m (Either DBFail BlockId)
insertBlock = insertByReturnKey

insertMeta :: (MonadIO m) => Meta -> ReaderT SqlBackend m (Either DBFail MetaId)
insertMeta = insertByReturnKey

insertPoolMetadata :: (MonadIO m) => PoolMetadata -> ReaderT SqlBackend m (Either DBFail PoolMetadataId)
insertPoolMetadata = insertByReturnKey

insertPoolMetadataReference
    :: MonadIO m
    => PoolMetadataReference
    -> ReaderT SqlBackend m (Either DBFail PoolMetadataReferenceId)
insertPoolMetadataReference = insertByReturnKey

insertReservedTicker :: (MonadIO m) => ReservedTicker -> ReaderT SqlBackend m (Either DBFail ReservedTickerId)
insertReservedTicker reservedTicker = do
    isUnique <- checkUnique reservedTicker
    -- If there is no unique constraint violated, insert, otherwise return error.
    case isUnique of
        Nothing -> insertByReturnKey reservedTicker
        Just _key -> return . Left . ReservedTickerAlreadyInserted $ reservedTickerName reservedTicker

insertDelistedPool :: (MonadIO m) => DelistedPool -> ReaderT SqlBackend m (Either DBFail DelistedPoolId)
insertDelistedPool = insertByReturnKey

insertRetiredPool :: (MonadIO m) => RetiredPool -> ReaderT SqlBackend m (Either DBFail RetiredPoolId)
insertRetiredPool = insertByReturnKey

insertAdminUser :: (MonadIO m) => AdminUser -> ReaderT SqlBackend m (Either DBFail AdminUserId)
insertAdminUser = insertByReturnKey

insertPoolMetadataFetchError
    :: (MonadIO m)
    => PoolMetadataFetchError
    -> ReaderT SqlBackend m (Either DBFail PoolMetadataFetchErrorId)
insertPoolMetadataFetchError = insertByReturnKey

-------------------------------------------------------------------------------

-- | Insert a record (with a Unique constraint), and return 'Right key' if the
-- record is inserted and 'Left key' if the record already exists in the DB.
insertByReturnKey
    :: ( AtLeastOneUniqueKey record
       , MonadIO m
       , PersistEntityBackend record ~ SqlBackend
       )
    => record -> ReaderT SqlBackend m (Either DBFail (Key record))
insertByReturnKey value = do
    res <- getByValue value
    case res of
        -- handle :: Exception e => (e -> IO a) -> IO a -> IO a
        Nothing -> mapReaderT (\insertedValue -> liftIO $ handle exceptionHandler insertedValue) (Right <$> insert value)
        Just r  -> pure . Right $ entityKey r
  where
    exceptionHandler :: MonadIO m => SqlError -> m (Either DBFail a)
    exceptionHandler e =
        liftIO . pure . Left . DbInsertError . show $ e


