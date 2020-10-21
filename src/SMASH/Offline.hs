{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SMASH.Offline
  ( fetchInsertNewPoolMetadata
  , runOfflineFetchThread
  ) where

import           Cardano.Prelude                  hiding (from, groupBy, retry)

import           Cardano.BM.Trace                 (Trace, logInfo, logWarning)

import           Control.Concurrent               (threadDelay)
import           Control.Monad.Trans.Except.Extra (handleExceptT, hoistEither,
                                                   left)

import           SMASH.DB                          (DataLayer (..),
                                                   PoolMetadataFetchError (..),
                                                   PoolMetadataReference (..),
                                                   PoolMetadataReferenceId,
                                                   postgresqlDataLayer,
                                                   runDbAction)
import           SMASH.FetchQueue
import           SMASH.Types                            (FetchError (..),
                                                   PoolFetchError (..),
                                                   PoolId (..),
                                                   PoolMetadataHash (..),
                                                   getPoolMetadataHash,
                                                   getPoolUrl, pomTicker)

import           Data.Aeson                       (eitherDecode')
import qualified Data.ByteString.Lazy             as LBS
import qualified Data.Text                        as Text
import qualified Data.Text.Encoding               as Text
import           Data.Time.Clock.POSIX            (posixSecondsToUTCTime)
import qualified Data.Time.Clock.POSIX            as Time

import qualified Cardano.Crypto.Hash.Blake2b      as Crypto
import qualified Cardano.Crypto.Hash.Class        as Crypto
import qualified SMASH.Cardano.Db.Schema          as DB

import qualified Data.ByteString.Base16           as B16

import           Database.Esqueleto               (Entity (..), SqlExpr,
                                                   ValueList, entityKey,
                                                   entityVal, from, groupBy,
                                                   in_, just, max_, notExists,
                                                   select, subList_select,
                                                   where_, (==.), (^.))
import           Database.Persist.Sql             (SqlBackend)

import           Network.HTTP.Client              (HttpException (..))
import qualified Network.HTTP.Client              as Http
import           Network.HTTP.Client.TLS          (tlsManagerSettings)
import qualified Network.HTTP.Types.Status        as Http

import qualified Shelley.Spec.Ledger.BaseTypes    as Shelley
import qualified Shelley.Spec.Ledger.TxData       as Shelley

-- This is an incredibly rough hack that adds asynchronous fetching of offline metadata.
-- This is not my best work.

fetchInsertNewPoolMetadata
    :: DataLayer
    -> Trace IO Text
    -> DB.PoolMetadataReferenceId
    -> PoolId
    -> Shelley.PoolMetaData
    -> IO ()
fetchInsertNewPoolMetadata dataLayer tracer refId poolId md  = do
    now <- Time.getPOSIXTime
    void . fetchInsertNewPoolMetadataOld dataLayer tracer $
      PoolFetchRetry
        { pfrReferenceId = refId
        , pfrPoolIdWtf = poolId
        , pfrPoolUrl = Shelley.urlToText (Shelley._poolMDUrl md)
        , pfrPoolMDHash = Shelley._poolMDHash md
        , pfrRetry = newRetry now
        }

fetchInsertNewPoolMetadataOld
    :: DataLayer
    -> Trace IO Text
    -> PoolFetchRetry
    -> IO (Maybe PoolFetchRetry)
fetchInsertNewPoolMetadataOld dataLayer tracer pfr = do

    -- We extract the @PoolId@ before so we can map the error to that @PoolId@.
    let poolId = pfrPoolIdWtf pfr

    res <- runExceptT (fetchInsert poolId)
    case res of
        Right () -> pure Nothing
        Left err -> do
            let poolHash = PoolMetadataHash . decodeUtf8 . B16.encode $ pfrPoolMDHash pfr
            let poolMetadataReferenceId = pfrReferenceId pfr
            let fetchError = renderFetchError err
            let currRetryCount = retryCount $ pfrRetry pfr

            -- Update retry timeout here as a psuedo-randomisation of retry.
            now <- Time.getPOSIXTime

            -- The generated fetch error
            let _poolFetchError = PoolFetchError now poolId poolHash fetchError

            let addFetchError = dlAddFetchError dataLayer

            _ <- addFetchError $ PoolMetadataFetchError
                (posixSecondsToUTCTime now)
                poolId
                poolHash
                poolMetadataReferenceId
                fetchError
                currRetryCount

            logWarning tracer fetchError

            pure . Just $ pfr { pfrRetry = nextRetry now (pfrRetry pfr) }
  where
    -- |We pass in the @PoolId@ so we can know from which pool the error occured.
    fetchInsert :: PoolId -> ExceptT FetchError IO ()
    fetchInsert poolId = do
        -- This is a bit bad to do each time, but good enough for now.
        manager <- liftIO $ Http.newManager tlsManagerSettings

        let poolMetadataURL = pfrPoolUrl pfr

        liftIO . logInfo tracer $ "Request: " <> poolMetadataURL

        request <- handleExceptT (\(_ :: HttpException) -> FEUrlParseFail poolId poolMetadataURL (pfrPoolUrl pfr))
                    $ Http.parseRequest (toS $ pfrPoolUrl pfr)

        (respBS, status) <- httpGetMax512Bytes poolId poolMetadataURL request manager

        when (Http.statusCode status /= 200) .
          left $ FEHttpResponse poolId poolMetadataURL (Http.statusCode status)

        liftIO . logInfo tracer $ "Response: " <> show (Http.statusCode status)

        decodedMetadata <- case eitherDecode' (LBS.fromStrict respBS) of
                            Left err     -> left $ FEJsonDecodeFail poolId poolMetadataURL (toS err)
                            Right result -> pure result

        -- Let's check the hash
        let hashFromMetadata = Crypto.digest (Proxy :: Proxy Crypto.Blake2b_256) respBS
            expectedHash = renderByteStringHex (pfrPoolMDHash pfr)

        if hashFromMetadata /= pfrPoolMDHash pfr
          then left $ FEHashMismatch poolId expectedHash (renderByteStringHex hashFromMetadata) poolMetadataURL
          else liftIO . logInfo tracer $ "Inserting pool data with hash: " <> expectedHash

        _ <- liftIO $
            (dlAddPoolMetadata postgresqlDataLayer)
                (Just $ pfrReferenceId pfr)
                (pfrPoolIdWtf pfr)
                (PoolMetadataHash . renderByteStringHex $ pfrPoolMDHash pfr)
                (decodeUtf8 respBS)
                (pomTicker decodedMetadata)

        liftIO $ logInfo tracer (decodeUtf8 respBS)

runOfflineFetchThread :: Trace IO Text -> IO ()
runOfflineFetchThread trce = do
    liftIO $ logInfo trce "Runing Offline fetch thread"
    fetchLoop postgresqlDataLayer trce emptyFetchQueue

-- -------------------------------------------------------------------------------------------------

fetchLoop :: DataLayer -> Trace IO Text -> FetchQueue -> IO ()
fetchLoop dataLayer trce =
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
          rs <- catMaybes <$> mapM (fetchInsertNewPoolMetadataOld dataLayer trce) runnable
          loop $ insertFetchQueue rs unrunnable

httpGetMax512Bytes
    :: PoolId
    -> Text
    -> Http.Request
    -> Http.Manager
    -> ExceptT FetchError IO (ByteString, Http.Status)
httpGetMax512Bytes poolId poolMetadataURL request manager = do
    res <- handleExceptT (convertHttpException poolId poolMetadataURL) $
            Http.withResponse request manager $ \responseBR -> do
              -- We read the first chunk that should contain all the bytes from the reponse.
              responseBSFirstChunk <- Http.brReadSome (Http.responseBody responseBR) 512
              -- If there are more bytes in the second chunk, we don't go any further since that
              -- violates the size constraint.
              responseBSSecondChunk <- Http.brReadSome (Http.responseBody responseBR) 1
              if LBS.null responseBSSecondChunk
                then pure $ Right (LBS.toStrict responseBSFirstChunk, Http.responseStatus responseBR)
                else pure $ Left $ FEDataTooLong poolId poolMetadataURL

    hoistEither res

convertHttpException :: PoolId -> Text -> HttpException -> FetchError
convertHttpException poolId poolMetadataURL he =
  case he of
    HttpExceptionRequest _req hec ->
      case hec of
        Http.ResponseTimeout      -> FETimeout poolId poolMetadataURL "Response"
        Http.ConnectionTimeout    -> FETimeout poolId poolMetadataURL "Connection"
        Http.ConnectionFailure {} -> FEConnectionFailure poolId poolMetadataURL
        other                     -> FEHttpException poolId poolMetadataURL (show other)
    InvalidUrlException url _ -> FEUrlParseFail poolId poolMetadataURL (Text.pack url)

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
          , pfrPoolMDHash = fst . B16.decode . encodeUtf8 $ getPoolMetadataHash (poolMetadataReferenceHash pmr)
          , pfrRetry = retry
          }

renderByteStringHex :: ByteString -> Text
renderByteStringHex = Text.decodeUtf8 . B16.encode

renderFetchError :: FetchError -> Text
renderFetchError fe =
  case fe of
    FEHashMismatch poolId xpt act poolMetaUrl ->
        mconcat
            [ "Hash mismatch from poolId '"
            , getPoolId poolId
            , "' when fetching metadata from '"
            , poolMetaUrl
            , "'. Expected "
            , xpt
            , " but got "
            , act
            , "."
            ]
    FEDataTooLong poolId poolMetaUrl ->
        mconcat
            [ "Offline pool data from poolId '"
            , getPoolId poolId
            , "' when fetching metadata from '"
            , poolMetaUrl
            , "' exceeded 512 bytes."
            ]
    FEUrlParseFail poolId poolMetaUrl err ->
        mconcat
            [ "URL parse error from poolId '"
            , getPoolId poolId
            , "' when fetching metadata from '"
            , poolMetaUrl
            , "' resulted in : "
            , err
            ]
    FEJsonDecodeFail poolId poolMetaUrl err ->
        mconcat
            [ "JSON decode error from poolId "
            , getPoolId poolId
            , "' when fetching metadata from '"
            , poolMetaUrl
            , "' resulted in : "
            , err
            ]
    FEHttpException poolId poolMetaUrl err ->
        mconcat
            [ "HTTP Exception from poolId "
            , getPoolId poolId
            , "' when fetching metadata from '"
            , poolMetaUrl
            , "' resulted in : "
            , err
            ]
    FEHttpResponse poolId poolMetaUrl sc ->
        mconcat
            [ "HTTP Response from poolId "
            , getPoolId poolId
            , "' when fetching metadata from '"
            , poolMetaUrl
            , "' resulted in : "
            , show sc
            ]
    FETimeout poolId poolMetaUrl ctx ->
        mconcat
            [ ctx
            , " timeout from poolId "
            , getPoolId poolId
            , "' when fetching metadata from '"
            , poolMetaUrl
            , "'."
            ]
    FEConnectionFailure poolId poolMetaUrl ->
        mconcat
            [ "Connection failure from poolId "
            , getPoolId poolId
            , "' when fetching metadata from '"
            , poolMetaUrl
            , "'."
            ]
    FEIOException err -> "IO Exception: " <> err

