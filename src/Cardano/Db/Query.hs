{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Db.Query
  ( DBFail (..)
  , queryTxMetadata
  , queryBlockNo
  , queryLatestBlock
  , queryLatestBlockNo
  , queryCheckPoints
  ) where

import           Cardano.Prelude hiding (from, maybeToEither, isJust, isNothing)

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

queryBlockNo :: MonadIO m => Word64 -> ReaderT SqlBackend m (Maybe Block)
queryBlockNo blkNo = do
  res <- select . from $ \ blk -> do
            where_ (blk ^. BlockBlockNo ==. just (val blkNo))
            pure blk
  pure $ fmap entityVal (listToMaybe res)

-- | Get the latest block.
queryLatestBlock :: MonadIO m => ReaderT SqlBackend m (Maybe Block)
queryLatestBlock = do
  res <- select $ from $ \ blk -> do
                orderBy [desc (blk ^. BlockSlotNo)]
                limit 1
                pure $ blk
  pure $ fmap entityVal (listToMaybe res)

-- | Get the 'BlockNo' of the latest block.
queryLatestBlockNo :: MonadIO m => ReaderT SqlBackend m (Maybe Word64)
queryLatestBlockNo = do
  res <- select $ from $ \ blk -> do
                where_ $ (isJust $ blk ^. BlockBlockNo)
                orderBy [desc (blk ^. BlockBlockNo)]
                limit 1
                pure $ blk ^. BlockBlockNo
  pure $ listToMaybe (catMaybes $ map unValue res)

queryCheckPoints :: MonadIO m => Word64 -> ReaderT SqlBackend m [(Word64, ByteString)]
queryCheckPoints limitCount = do
    latest <- select $ from $ \ blk -> do
                where_ $ (isJust $ blk ^. BlockSlotNo)
                orderBy [desc (blk ^. BlockSlotNo)]
                limit 1
                pure $ (blk ^. BlockSlotNo)
    case join (unValue <$> listToMaybe latest) of
      Nothing -> pure []
      Just slotNo -> mapMaybeM querySpacing (calcSpacing slotNo)
  where
    querySpacing :: MonadIO m => Word64 -> ReaderT SqlBackend m (Maybe (Word64, ByteString))
    querySpacing blkNo = do
       rows <- select $ from $ \ blk -> do
                  where_ $ (blk ^. BlockSlotNo ==. just (val blkNo))
                  pure $ (blk ^. BlockSlotNo, blk ^. BlockHash)
       pure $ join (convert <$> listToMaybe rows)

    convert :: (Value (Maybe Word64), Value ByteString) -> Maybe (Word64, ByteString)
    convert (va, vb) =
      case (unValue va, unValue vb) of
        (Nothing, _ ) -> Nothing
        (Just a, b) -> Just (a, b)

    calcSpacing :: Word64 -> [Word64]
    calcSpacing end =
      if end > 2 * limitCount
        then [ end, end - end `div` limitCount .. 1 ]
        else [ end, end - 2 .. 1 ]


------------------------------------------------------------------------------------

maybeToEither :: e -> (a -> b) -> Maybe a -> Either e b
maybeToEither e f =
  maybe (Left e) (Right . f)

-- Filter out 'Nothing' from a 'Maybe a'.
isJust :: PersistField a => SqlExpr (Value (Maybe a)) -> SqlExpr (Value Bool)
isJust = not_ . isNothing




