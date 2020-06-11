{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Db.Query
  ( DBFail (..)
  , queryTxMetadata
  ) where

import           Cardano.Prelude hiding (from, maybeToEither)

import           Control.Monad (join)
import           Control.Monad.Extra (mapMaybeM)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import           Control.Monad.Trans.Reader (ReaderT)

import           Data.ByteString.Char8 (ByteString)
import           Data.Fixed (Micro)
import           Data.Maybe (catMaybes, fromMaybe, listToMaybe)
import           Data.Ratio ((%), numerator)
import           Data.Text (Text)
import           Data.Time.Clock (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import           Data.Time.Clock.POSIX (POSIXTime, utcTimeToPOSIXSeconds)
import           Data.Word (Word16, Word64)

import           Database.Esqueleto (Entity (..), From, InnerJoin (..), LeftOuterJoin (..),
                    PersistField, SqlExpr, SqlQuery, Value (..), ValueList,
                    (^.), (==.), (<=.), (&&.), (||.), (>.),
                    count, countRows, desc, entityKey, entityVal, from, exists,
                    in_, isNothing, just, limit, max_, min_, not_, notExists, on, orderBy,
                    select, subList_select, sum_, unValue, unSqlBackendKey, val, where_)
import           Database.Persist.Sql (SqlBackend)

import           Cardano.Db.Error
import           Cardano.Db.Schema

-- | Get the 'Block' associated with the given hash.
queryTxMetadata :: MonadIO m => ByteString -> ReaderT SqlBackend m (Either DBFail TxMetadata)
queryTxMetadata hash = do
  res <- select . from $ \ blk -> do
            where_ (blk ^. TxMetadataHash ==. val hash)
            pure blk
  pure $ maybeToEither (DbLookupTxMetadataHash hash) entityVal (listToMaybe res)

------------------------------------------------------------------------------------

maybeToEither :: e -> (a -> b) -> Maybe a -> Either e b
maybeToEither e f =
  maybe (Left e) (Right . f)


