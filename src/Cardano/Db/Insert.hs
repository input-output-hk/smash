{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}

module Cardano.Db.Insert
  ( insertBlock
  , insertMeta
  , insertTxMetadata
  , insertPoolMetaData
  , insertDelistedPool
  , insertAdminUser

  -- Export mainly for testing.
  , insertByReturnKey
  ) where

import           Cardano.Prelude hiding (Meta)

import           Control.Monad.IO.Class (MonadIO)
import           Control.Monad.Trans.Reader (ReaderT)

import           Database.Persist.Class (AtLeastOneUniqueKey, Key, PersistEntityBackend,
                    getByValue, insert)
import           Database.Persist.Sql (SqlBackend)
import           Database.Persist.Types (entityKey)

import           Cardano.Db.Schema

insertBlock :: (MonadIO m) => Block -> ReaderT SqlBackend m BlockId
insertBlock = insertByReturnKey

insertMeta :: (MonadIO m) => Meta -> ReaderT SqlBackend m MetaId
insertMeta = insertByReturnKey

insertTxMetadata :: (MonadIO m) => TxMetadata -> ReaderT SqlBackend m TxMetadataId
insertTxMetadata = insertByReturnKey

insertPoolMetaData :: (MonadIO m) => PoolMetaData -> ReaderT SqlBackend m PoolMetaDataId
insertPoolMetaData = insertByReturnKey

insertDelistedPool :: (MonadIO m) => DelistedPool -> ReaderT SqlBackend m DelistedPoolId
insertDelistedPool = insertByReturnKey

insertAdminUser :: (MonadIO m) => AdminUser -> ReaderT SqlBackend m AdminUserId
insertAdminUser = insertByReturnKey

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

