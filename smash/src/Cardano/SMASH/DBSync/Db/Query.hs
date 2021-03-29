{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.SMASH.DBSync.Db.Query
  ( DBFail (..)
  , querySchemaVersion
  , querySlotHash
  , queryLatestSlotNo
  , queryAllPools
  , queryPoolByPoolId
  , queryAllPoolMetadata
  , queryPoolMetadata
  , queryBlockCount
  , queryBlockNo
  , queryBlockId
  , queryMeta
  , queryLatestBlock
  , queryLatestBlockNo
  , queryCheckPoints
  , queryDelistedPool
  , queryAllDelistedPools
  , queryAllReservedTickers
  , queryReservedTicker
  , queryAdminUsers
  , queryPoolMetadataFetchError
  , queryPoolMetadataFetchErrorByTime
  , queryAllRetiredPools
  , queryRetiredPool
  ) where

import           Cardano.Prelude                hiding (Meta, from, isJust,
                                                 isNothing, maybeToEither)

import           Control.Monad.Extra            (mapMaybeM)

import           Data.Time.Clock                (UTCTime)

import           Database.Esqueleto             (Entity, PersistField, SqlExpr,
                                                 Value, ValueList, countRows,
                                                 desc, entityVal, from,
                                                 isNothing, just, limit, notIn,
                                                 not_, orderBy, select,
                                                 subList_select, unValue, val,
                                                 where_, (&&.), (==.), (>=.),
                                                 (^.))
import           Database.Persist.Sql           (SqlBackend, selectList)

import           Cardano.Slotting.Slot          (SlotNo (..))

import           Cardano.SMASH.DBSync.Db.Error
import           Cardano.SMASH.DBSync.Db.Schema
import qualified Cardano.SMASH.DBSync.Db.Types  as Types

-- | Query the schema version of the database.
querySchemaVersion :: MonadIO m => ReaderT SqlBackend m (Maybe SchemaVersion)
querySchemaVersion = do
  res <- select . from $ \ sch -> do
            orderBy [desc (sch ^. SchemaVersionStageOne)]
            pure sch
  pure $ entityVal <$> listToMaybe res

-- {-# WARNING querySlotHash "Include in the DataLayer!" #-}
querySlotHash :: MonadIO m => SlotNo -> ReaderT SqlBackend m (Maybe (SlotNo, ByteString))
querySlotHash slotNo = do
  res <- select . from $ \ blk -> do
            where_ (blk ^. BlockSlotNo ==. just (val $ unSlotNo slotNo))
            pure (blk ^. BlockHash)
  pure $ (\vh -> (slotNo, unValue vh)) <$> listToMaybe res

-- | Get the latest slot number
queryLatestSlotNo :: MonadIO m => ReaderT SqlBackend m Word64
queryLatestSlotNo = do
  res <- select . from $ \ blk -> do
            where_ (isJust $ blk ^. BlockSlotNo)
            orderBy [desc (blk ^. BlockSlotNo)]
            limit 1
            pure $ blk ^. BlockSlotNo
  pure $ fromMaybe 0 (listToMaybe $ mapMaybe unValue res)

-- |Return all pools.
queryAllPools :: MonadIO m => ReaderT SqlBackend m [Pool]
queryAllPools = do
  res <- selectList [] []
  pure $ entityVal <$> res

-- |Return pool, that is not RETIRED!
queryPoolByPoolId :: MonadIO m => Types.PoolId -> ReaderT SqlBackend m (Either DBFail Pool)
queryPoolByPoolId poolId = do
  res <- select . from $ \(pool :: SqlExpr (Entity Pool)) -> do
            where_ (pool ^. PoolPoolId ==. val poolId
                &&. pool ^. PoolPoolId `notIn` retiredPoolsPoolId)
            pure pool
  pure $ maybeToEither RecordDoesNotExist entityVal (listToMaybe res)
  where
    -- |Subselect that selects all the retired pool ids.
    retiredPoolsPoolId :: SqlExpr (ValueList (Types.PoolId))
    retiredPoolsPoolId =
        subList_select . from $ \(retiredPool :: SqlExpr (Entity RetiredPool)) ->
        return $ retiredPool ^. RetiredPoolPoolId

-- |Return all retired pools.
queryAllPoolMetadata :: MonadIO m => ReaderT SqlBackend m [PoolMetadata]
queryAllPoolMetadata = do
  res <- selectList [] []
  pure $ entityVal <$> res

-- | Get the 'Block' associated with the given hash.
-- We use the @Types.PoolId@ to get the nice error message out.
queryPoolMetadata :: MonadIO m => Types.PoolId -> Types.PoolMetadataHash -> ReaderT SqlBackend m (Either DBFail PoolMetadata)
queryPoolMetadata poolId poolMetadataHash' = do
  res <- select . from $ \ poolMetadata -> do
            where_ (poolMetadata ^. PoolMetadataPoolId ==. val poolId
                &&. poolMetadata ^. PoolMetadataHash ==. val poolMetadataHash'
                &&. poolMetadata ^. PoolMetadataPoolId `notIn` retiredPoolsPoolId) -- This is now optional
            pure poolMetadata
  pure $ maybeToEither (DbLookupPoolMetadataHash poolId poolMetadataHash') entityVal (listToMaybe res)
  where
    -- |Subselect that selects all the retired pool ids.
    retiredPoolsPoolId :: SqlExpr (ValueList (Types.PoolId))
    retiredPoolsPoolId =
        subList_select . from $ \(retiredPool :: SqlExpr (Entity RetiredPool)) ->
        return $ retiredPool ^. RetiredPoolPoolId

-- |Return all retired pools.
queryAllRetiredPools :: MonadIO m => ReaderT SqlBackend m [RetiredPool]
queryAllRetiredPools = do
  res <- selectList [] []
  pure $ entityVal <$> res

-- |Query retired pools.
queryRetiredPool :: MonadIO m => Types.PoolId -> ReaderT SqlBackend m (Either DBFail RetiredPool)
queryRetiredPool poolId = do
  res <- select . from $ \retiredPools -> do
            where_ (retiredPools ^. RetiredPoolPoolId ==. val poolId)
            pure retiredPools
  pure $ maybeToEither RecordDoesNotExist entityVal (listToMaybe res)

-- | Count the number of blocks in the Block table.
queryBlockCount :: MonadIO m => ReaderT SqlBackend m Word
queryBlockCount = do
  res <- select . from $ \ (_ :: SqlExpr (Entity Block)) -> do
            pure countRows
  pure $ maybe 0 unValue (listToMaybe res)

queryBlockNo :: MonadIO m => Word64 -> ReaderT SqlBackend m (Maybe Block)
queryBlockNo blkNo = do
  res <- select . from $ \ blk -> do
            where_ (blk ^. BlockBlockNo ==. just (val blkNo))
            pure blk
  pure $ fmap entityVal (listToMaybe res)

-- | Get the 'BlockId' associated with the given hash.
queryBlockId :: MonadIO m => ByteString -> ReaderT SqlBackend m (Either DBFail BlockId)
queryBlockId hash = do
  res <- select . from $ \ blk -> do
            where_ (blk ^. BlockHash ==. val hash)
            pure $ blk ^. BlockId
  pure $ maybeToEither (DbLookupBlockHash hash) unValue (listToMaybe res)

{-# INLINABLE queryMeta #-}
-- | Get the network metadata.
queryMeta :: MonadIO m => ReaderT SqlBackend m (Either DBFail Meta)
queryMeta = do
  res <- select . from $ \ (meta :: SqlExpr (Entity Meta)) -> do
            pure meta
  pure $ case res of
            []  -> Left DbMetaEmpty
            [m] -> Right $ entityVal m
            _   -> Left DbMetaMultipleRows

-- | Get the latest block.
queryLatestBlock :: MonadIO m => ReaderT SqlBackend m (Maybe Block)
queryLatestBlock = do
  res <- select $ from $ \ blk -> do
                where_ (isJust $ blk ^. BlockSlotNo)
                orderBy [desc (blk ^. BlockSlotNo)]
                limit 1
                pure blk
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
      Nothing     -> pure []
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
        (Just a, b)   -> Just (a, b)

    calcSpacing :: Word64 -> [Word64]
    calcSpacing end =
      if end > 2 * limitCount
        then [ end, end - end `div` limitCount .. 1 ]
        else [ end, end - 2 .. 1 ]

-- | Check if the hash is in the table.
queryDelistedPool :: MonadIO m => Types.PoolId -> ReaderT SqlBackend m Bool
queryDelistedPool poolId = do
  res <- select . from $ \(pool :: SqlExpr (Entity DelistedPool)) -> do
            where_ (pool ^. DelistedPoolPoolId ==. val poolId)
            pure pool
  pure $ maybe False (\_ -> True) (listToMaybe res)

-- |Return all delisted pools.
queryAllDelistedPools :: MonadIO m => ReaderT SqlBackend m [DelistedPool]
queryAllDelistedPools = do
  res <- selectList [] []
  pure $ entityVal <$> res

-- |Return all reserved tickers.
queryAllReservedTickers :: MonadIO m => ReaderT SqlBackend m [ReservedTicker]
queryAllReservedTickers = do
  res <- selectList [] []
  pure $ entityVal <$> res

-- | Check if the ticker is in the table.
queryReservedTicker :: MonadIO m => Types.TickerName -> Types.PoolMetadataHash -> ReaderT SqlBackend m (Maybe ReservedTicker)
queryReservedTicker reservedTickerName' poolMetadataHash' = do
  res <- select . from $ \(reservedTicker :: SqlExpr (Entity ReservedTicker)) -> do
            where_ (reservedTicker ^. ReservedTickerName ==. val reservedTickerName'
                &&. reservedTicker ^. ReservedTickerPoolHash ==. val poolMetadataHash')

            limit 1
            pure $ reservedTicker
  pure $ fmap entityVal (listToMaybe res)

-- | Query all admin users for authentication.
queryAdminUsers :: MonadIO m => ReaderT SqlBackend m [AdminUser]
queryAdminUsers = do
  res <- selectList [] []
  pure $ entityVal <$> res

-- | Query all the errors we have.
queryPoolMetadataFetchError :: MonadIO m => Maybe Types.PoolId -> ReaderT SqlBackend m [PoolMetadataFetchError]
queryPoolMetadataFetchError Nothing = do
  res <- selectList [] []
  pure $ entityVal <$> res

queryPoolMetadataFetchError (Just poolId) = do
  res <- select . from $ \(poolMetadataFetchError :: SqlExpr (Entity PoolMetadataFetchError)) -> do
            where_ (poolMetadataFetchError ^. PoolMetadataFetchErrorPoolId ==. val poolId)
            pure $ poolMetadataFetchError
  pure $ fmap entityVal res

-- We currently query the top 10 errors (chronologically) when we don't have the time parameter, but we would ideally
-- want to see the top 10 errors from _different_ pools (group by), using something like:
-- select pool_id, pool_hash, max(retry_count) from pool_metadata_fetch_error group by pool_id, pool_hash;
queryPoolMetadataFetchErrorByTime
    :: MonadIO m
    => Types.PoolId
    -> Maybe UTCTime
    -> ReaderT SqlBackend m [PoolMetadataFetchError]
queryPoolMetadataFetchErrorByTime poolId Nothing = do
  res <- select . from $ \(poolMetadataFetchError :: SqlExpr (Entity PoolMetadataFetchError)) -> do
            where_ (poolMetadataFetchError ^. PoolMetadataFetchErrorPoolId ==. val poolId)
            orderBy [desc (poolMetadataFetchError ^. PoolMetadataFetchErrorFetchTime)]
            limit 10
            pure $ poolMetadataFetchError
  pure $ fmap entityVal res

queryPoolMetadataFetchErrorByTime poolId (Just fromTime) = do
  res <- select . from $ \(poolMetadataFetchError :: SqlExpr (Entity PoolMetadataFetchError)) -> do
            where_ (poolMetadataFetchError ^. PoolMetadataFetchErrorPoolId ==. val poolId
                &&. poolMetadataFetchError ^. PoolMetadataFetchErrorFetchTime >=. val fromTime)
            orderBy [desc (poolMetadataFetchError ^. PoolMetadataFetchErrorFetchTime)]
            pure $ poolMetadataFetchError
  pure $ fmap entityVal res

------------------------------------------------------------------------------------

maybeToEither :: e -> (a -> b) -> Maybe a -> Either e b
maybeToEither e f =
  maybe (Left e) (Right . f)

-- Filter out 'Nothing' from a 'Maybe a'.
isJust :: PersistField a => SqlExpr (Value (Maybe a)) -> SqlExpr (Value Bool)
isJust = not_ . isNothing

