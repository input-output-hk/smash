{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}

module Offline
  ( fetchInsertNewPoolMetadata
  , runOfflineFetchThread
  ) where

import           Cardano.Prelude hiding (from, groupBy, retry)

import           Cardano.BM.Trace (Trace, logWarning, logInfo)

import           Control.Concurrent (threadDelay)
import           Control.Monad.Trans.Except.Extra (handleExceptT, hoistEither, left)

import           DB (DataLayer (..), PoolMetadataReference (..), PoolMetadataReferenceId,
                    postgresqlDataLayer, runDbAction)
import           FetchQueue
import           Types (PoolId, PoolMetadataHash (..), getPoolMetadataHash, getPoolUrl, pomTicker)

import           Data.Aeson (eitherDecode')
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Time.Clock.POSIX as Time

import qualified Cardano.Crypto.Hash.Class as Crypto
import qualified Cardano.Crypto.Hash.Blake2b as Crypto
import qualified Cardano.Db.Schema as DB

import qualified Data.ByteString.Base16 as Base16

import           Database.Esqueleto (Entity (..), SqlExpr, ValueList, (^.), (==.),
                    entityKey, entityVal, from, groupBy, in_, just, max_, notExists,
                    select, subList_select, where_)
import           Database.Persist.Sql (SqlBackend)

import           Network.HTTP.Client (HttpException (..))
import qualified Network.HTTP.Client as Http
import           Network.HTTP.Client.TLS (tlsManagerSettings)
import qualified Network.HTTP.Types.Status as Http

import qualified Shelley.Spec.Ledger.BaseTypes as Shelley
import qualified Shelley.Spec.Ledger.TxData as Shelley

-- This is an incredibly rough hack that adds asynchronous fetching of offline metadata.
-- This is not my best work.


data FetchError
  = FEHashMismatch !Text !Text
  | FEDataTooLong
  | FEUrlParseFail !Text
  | FEJsonDecodeFail !Text
  | FEHttpException !Text
  | FEHttpResponse !Int
  | FEIOException !Text
  | FETimeout !Text
  | FEConnectionFailure

fetchInsertNewPoolMetadata
    :: Trace IO Text
    -> DB.PoolMetadataReferenceId
    -> PoolId
    -> Shelley.PoolMetaData
    -> IO ()
fetchInsertNewPoolMetadata tracer refId poolId md  = do
    now <- Time.getPOSIXTime
    void . fetchInsertNewPoolMetadataOld tracer $
      PoolFetchRetry
        { pfrReferenceId = refId
        , pfrPoolIdWtf = poolId
        , pfrPoolUrl = Shelley.urlToText (Shelley._poolMDUrl md)
        , pfrPoolMDHash = Shelley._poolMDHash md
        , pfrRetry = newRetry now
        }

fetchInsertNewPoolMetadataOld
    :: Trace IO Text
    -> PoolFetchRetry
    -> IO (Maybe PoolFetchRetry)
fetchInsertNewPoolMetadataOld tracer pfr = do
    res <- runExceptT fetchInsert
    case res of
        Right () -> pure Nothing
        Left err -> do
            logWarning tracer $ renderFetchError err
            -- Update retry timeout here as a psuedo-randomisation of retry.
            now <- Time.getPOSIXTime
            pure . Just $ pfr { pfrRetry = nextRetry now (pfrRetry pfr) }
  where
    fetchInsert :: ExceptT FetchError IO ()
    fetchInsert = do
        -- This is a bit bad to do each time, but good enough for now.
        manager <- liftIO $ Http.newManager tlsManagerSettings

        liftIO . logInfo tracer $ "Request: " <> pfrPoolUrl pfr

        request <- handleExceptT (\(_ :: HttpException) -> FEUrlParseFail $ pfrPoolUrl pfr)
                    $ Http.parseRequest (toS $ pfrPoolUrl pfr)

        (respBS, status) <- httpGetMax512Bytes request manager

        when (Http.statusCode status /= 200) .
          left $ FEHttpResponse (Http.statusCode status)

        liftIO . logInfo tracer $ "Response: " <> show (Http.statusCode status)

        decodedMetadata <- case eitherDecode' (LBS.fromStrict respBS) of
                            Left err -> left $ FEJsonDecodeFail (toS err)
                            Right result -> pure result

        -- Let's check the hash
        let hashFromMetadata = Crypto.digest (Proxy :: Proxy Crypto.Blake2b_256) respBS
            expectedHash = renderByteStringHex (pfrPoolMDHash pfr)

        if hashFromMetadata /= pfrPoolMDHash pfr
          then left $ FEHashMismatch expectedHash (renderByteStringHex hashFromMetadata)
          else liftIO . logInfo tracer $ "Inserting pool data with hash: " <> expectedHash

        _ <- liftIO $
            (dlAddPoolMetadata postgresqlDataLayer)
                (Just $ pfrReferenceId pfr)
                (pfrPoolIdWtf pfr)
                (PoolMetadataHash $ pfrPoolMDHash pfr)
                (decodeUtf8 respBS)
                (pomTicker decodedMetadata)

        liftIO $ logInfo tracer (decodeUtf8 respBS)

runOfflineFetchThread :: Trace IO Text -> IO ()
runOfflineFetchThread trce = do
    liftIO $ logInfo trce "Runing Offline fetch thread"
    fetchLoop trce emptyFetchQueue

-- -------------------------------------------------------------------------------------------------

fetchLoop :: Trace IO Text -> FetchQueue -> IO ()
fetchLoop trce =
    loop
  where
    loop :: FetchQueue -> IO ()
    loop fq = do
      now <- Time.getPOSIXTime
      pools <- runDbAction Nothing $ queryPoolFetchRetry (newRetry now)
      let newFq = insertFetchQueue pools fq
          (runnable, unrunnable) = partitionFetchQueue newFq now
      logInfo trce $
        mconcat
          [ "fetchLoop: ", show (length runnable), " runnable, "
          , show (lenFetchQueue unrunnable), " pending"
          ]
      if null runnable
        then do
          threadDelay (20 * 1000 * 1000) -- 20 seconds
          loop unrunnable
        else do
          liftIO $ logInfo trce $ "Pools without offline metadata: " <> show (length runnable)
          rs <- catMaybes <$> mapM (fetchInsertNewPoolMetadataOld trce) pools
          loop $ insertFetchQueue rs unrunnable

httpGetMax512Bytes :: Http.Request -> Http.Manager -> ExceptT FetchError IO (ByteString, Http.Status)
httpGetMax512Bytes request manager = do
    res <- handleExceptT convertHttpException $
            Http.withResponse request manager $ \responseBR -> do
              -- We read the first chunk that should contain all the bytes from the reponse.
              responseBSFirstChunk <- Http.brReadSome (Http.responseBody responseBR) 512
              -- If there are more bytes in the second chunk, we don't go any further since that
              -- violates the size constraint.
              responseBSSecondChunk <- Http.brReadSome (Http.responseBody responseBR) 1
              if LBS.null responseBSSecondChunk
                then pure $ Right (LBS.toStrict responseBSFirstChunk, Http.responseStatus responseBR)
                else pure $ Left FEDataTooLong
    hoistEither res

convertHttpException :: HttpException -> FetchError
convertHttpException he =
  case he of
    HttpExceptionRequest _req hec ->
      case hec of
        Http.ResponseTimeout -> FETimeout "Response"
        Http.ConnectionTimeout -> FETimeout "Connection"
        Http.ConnectionFailure {} -> FEConnectionFailure
        other -> FEHttpException (show other)
    InvalidUrlException url _ -> FEUrlParseFail (Text.pack url)


-- select * from pool_metadata_reference
--     where id in (select max(id) from pool_metadata_reference group by pool_id)
--     and not exists (select * from pool_metadata where pmr_id = pool_metadata_reference.id) ;

-- Get a list of the pools for which there is a PoolMetadataReference entry but there is
-- no PoolMetadata entry.
-- This is a bit questionable because it assumes that the autogenerated 'id' primary key
-- is a reliable proxy for time, ie higher 'id' was added later in time.
queryPoolFetchRetry :: MonadIO m => Retry -> ReaderT SqlBackend m [PoolFetchRetry]
queryPoolFetchRetry retry = do
    res <- select . from $ \ pmr -> do
              where_ (just (pmr ^. DB.PoolMetadataReferenceId) `in_` latestReferences)
              where_ (notExists . from $ \ pod -> where_ (pod ^. DB.PoolMetadataPmrId ==. just (pmr ^. DB.PoolMetadataReferenceId)))
              pure pmr
    pure $ map convert res
  where
    latestReferences :: SqlExpr (ValueList (Maybe PoolMetadataReferenceId))
    latestReferences =
      subList_select . from $ \ pfr -> do
        groupBy (pfr ^. DB.PoolMetadataReferencePoolId)
        pure $ max_ (pfr ^. DB.PoolMetadataReferenceId)

    convert :: Entity PoolMetadataReference -> PoolFetchRetry
    convert entity =
      let pmr = entityVal entity in
        PoolFetchRetry
          { pfrReferenceId = entityKey entity
          , pfrPoolIdWtf = DB.poolMetadataReferencePoolId pmr
          , pfrPoolUrl = getPoolUrl $ poolMetadataReferenceUrl pmr
          , pfrPoolMDHash = getPoolMetadataHash (poolMetadataReferenceHash pmr)
          , pfrRetry = retry
          }


renderByteStringHex :: ByteString -> Text
renderByteStringHex = Text.decodeUtf8 . Base16.encode

renderFetchError :: FetchError -> Text
renderFetchError fe =
  case fe of
    FEHashMismatch xpt act -> mconcat [ "Hash mismatch. Expected ", xpt, " but got ", act, "." ]
    FEDataTooLong -> "Offline pool data exceeded 512 bytes."
    FEUrlParseFail err -> "URL parse error: " <> err
    FEJsonDecodeFail err -> "JSON decode error: " <> err
    FEHttpException err -> "HTTP Exception: " <> err
    FEHttpResponse sc -> "HTTP Response : " <> show sc
    FEIOException err -> "IO Exception: " <> err
    FETimeout ctx -> ctx <> " timeout"
    FEConnectionFailure -> "Connection failure"
