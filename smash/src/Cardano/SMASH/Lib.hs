{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}

module Cardano.SMASH.Lib
    ( Configuration (..)
    , DBFail (..) -- We need to see errors clearly outside
    , defaultConfiguration
    , runApp
    , runAppStubbed
    -- * For manipulating admin users
    , createAdminUser
    , deleteAdminUser
    ) where

#ifdef TESTING_MODE
import           Cardano.SMASH.Types         (PoolIdBlockNumber (..), pomTicker)
import           Data.Aeson                  (eitherDecode')
import qualified Data.ByteString.Lazy        as BL
#endif

import           Cardano.Prelude             hiding (Handler)

import           Data.Aeson                  (encode)

import           Data.Swagger                (Contact (..), Info (..),
                                              License (..), Swagger (..),
                                              URL (..))
import           Data.Time                   (UTCTime, addUTCTime,
                                              getCurrentTime, nominalDay)
import           Data.Version                (showVersion)

import           Network.Wai.Handler.Warp    (defaultSettings, runSettings,
                                              setBeforeMainLoop, setPort)

import           Servant                     (Application, BasicAuthCheck (..),
                                              BasicAuthData (..),
                                              BasicAuthResult (..),
                                              Context (..), Handler (..),
                                              Header, Headers, Server, err400,
                                              err403, err404, errBody,
                                              serveWithContext, (:<|>) (..))
import           Servant.API.ResponseHeaders (addHeader)
import           Servant.Swagger             (toSwagger)

import           Cardano.SMASH.API           (API, fullAPI, smashApi)
import           Cardano.SMASH.DB            (AdminUser (..), DBFail (..),
                                              DataLayer (..),
                                              createCachedDataLayer)
import           Cardano.SMASH.HttpClient    (httpClientFetchPolicies,
                                              renderHttpClientError)

import           Cardano.SMASH.Types         (ApiResult (..),
                                              ApplicationUser (..),
                                              ApplicationUsers (..),
                                              Configuration (..),
                                              HealthStatus (..),
                                              PolicyResult (..), PoolFetchError,
                                              PoolId (..), PoolMetadataHash,
                                              PoolMetadataRaw (..),
                                              SmashURL (..), TickerName,
                                              TimeStringFormat (..),
                                              UniqueTicker (..), User,
                                              UserValidity (..),
                                              checkIfUserValid,
                                              defaultConfiguration,
                                              stubbedApplicationUsers)

import           Paths_smash                 (version)

-- | Cache control header.
data CacheControl
    = NoCache
    | CacheSeconds Int
    | CacheOneHour
    | CacheOneDay

-- | Render the cache control header.
cacheControlHeader :: CacheControl -> Text
cacheControlHeader NoCache = "no-store"
cacheControlHeader (CacheSeconds sec) = "max-age=" <> show sec
cacheControlHeader CacheOneHour = cacheControlHeader $ CacheSeconds (60 * 60)
cacheControlHeader CacheOneDay = cacheControlHeader $ CacheSeconds (24 * 60 * 60)

-- | Swagger spec for Todo API.
todoSwagger :: Swagger
todoSwagger =
    let swaggerDefinition = toSwagger smashApi

    in swaggerDefinition {_swaggerInfo = swaggerInfo}
  where
    smashVersion :: Text
    smashVersion = toS $ showVersion version

    swaggerInfo :: Info
    swaggerInfo = Info
        { _infoTitle = "Smash"
        , _infoDescription = Just "Stakepool Metadata Aggregation Server"
        , _infoTermsOfService = Nothing
        , _infoContact = Just $ Contact
            { _contactName = Just "IOHK"
            , _contactUrl = Just $ URL "https://iohk.io/"
            , _contactEmail = Just "operations@iohk.io"
            }

        , _infoLicense = Just $ License
            { _licenseName = "APACHE2"
            , _licenseUrl = Just $ URL "https://github.com/input-output-hk/smash/blob/master/LICENSE"
            }
        , _infoVersion = smashVersion
        }

runApp :: DataLayer -> Configuration -> IO ()
runApp dataLayer configuration = do
    let port = cPortNumber configuration
    let settings =
          setPort port $
          setBeforeMainLoop (hPutStrLn stderr ("listening on port " ++ show port)) $
          defaultSettings

    runSettings settings =<< (mkApp dataLayer configuration)

runAppStubbed :: Configuration -> IO ()
runAppStubbed configuration = do
    let port = cPortNumber configuration
    let settings =
          setPort port $
          setBeforeMainLoop (hPutStrLn stderr ("listening on port " ++ show port)) $
          defaultSettings

    runSettings settings =<< mkAppStubbed configuration

mkAppStubbed :: Configuration -> IO Application
mkAppStubbed configuration = do

    dataLayer <- createCachedDataLayer Nothing

    return $ serveWithContext
        fullAPI
        (basicAuthServerContext stubbedApplicationUsers)
        (server configuration dataLayer)

mkApp :: DataLayer -> Configuration -> IO Application
mkApp dataLayer configuration = do

    -- Ugly hack, wait 2s for migrations to run for the admin user to be created.
    -- You can always run the migrations first.
    threadDelay 2_000_000

    -- Fetch the admin users from the DB.
    let getAdminUsers = dlGetAdminUsers dataLayer
    adminUsers <- getAdminUsers

    -- This is pretty close to the top and we can't handle this.
    let adminUsers' =   case adminUsers of
                            Left err -> panic $ "Error with fetching application users! " <> show err
                            Right users -> users

    let applicationUsers = ApplicationUsers $ map convertToAppUsers adminUsers'

    return $ serveWithContext
        fullAPI
        (basicAuthServerContext applicationUsers)
        (server configuration dataLayer)
  where
    convertToAppUsers :: AdminUser -> ApplicationUser
    convertToAppUsers (AdminUser username' password') = ApplicationUser username' password'

-- Generic throwing of exception when something goes bad.
throwDBFailException :: DBFail -> IO (ApiResult DBFail a)
throwDBFailException dbFail = throwIO $ err400 { errBody = encode dbFail }

-- | We need to supply our handlers with the right Context.
basicAuthServerContext :: ApplicationUsers -> Context (BasicAuthCheck User ': '[])
basicAuthServerContext applicationUsers = (authCheck applicationUsers) :. EmptyContext
  where
    -- | 'BasicAuthCheck' holds the handler we'll use to verify a username and password.
    authCheck :: ApplicationUsers -> BasicAuthCheck User
    authCheck applicationUsers' =

        let check' :: BasicAuthData -> IO (BasicAuthResult User)
            check' (BasicAuthData username' password') = do
                let usernameText = decodeUtf8 username'
                let passwordText = decodeUtf8 password'

                let applicationUser  = ApplicationUser usernameText passwordText
                let userAuthValidity = checkIfUserValid applicationUsers' applicationUser

                case userAuthValidity of
                    UserValid user -> pure (Authorized user)
                    UserInvalid    -> pure Unauthorized

        in BasicAuthCheck check'

createAdminUser :: DataLayer -> ApplicationUser -> IO (Either DBFail AdminUser)
createAdminUser dataLayer applicationUser = do
    let addAdminUser = dlAddAdminUser dataLayer
    addAdminUser applicationUser

deleteAdminUser :: DataLayer -> ApplicationUser -> IO (Either DBFail AdminUser)
deleteAdminUser dataLayer applicationUser = do
    let removeAdminUser = dlRemoveAdminUser dataLayer
    removeAdminUser applicationUser

-- | Natural transformation from @IO@ to @Handler@.
convertIOToHandler :: IO a -> Handler a
convertIOToHandler = Handler . ExceptT . try

-- | Combined server of a Smash service with Swagger documentation.
server :: Configuration -> DataLayer -> Server API
server _configuration dataLayer
    =       return todoSwagger
    :<|>    getPoolOfflineMetadata dataLayer
    :<|>    getHealthStatus
    :<|>    getReservedTickers dataLayer
    :<|>    getDelistedPools dataLayer
    :<|>    delistPool dataLayer
    :<|>    enlistPool dataLayer
    :<|>    getPoolErrorAPI dataLayer
    :<|>    getRetiredPools dataLayer
    :<|>    checkPool dataLayer
    :<|>    addTicker dataLayer
    :<|>    fetchPolicies dataLayer
#ifdef TESTING_MODE
    :<|>    retirePool dataLayer
    :<|>    addPool dataLayer
#endif


-- 403 if it is delisted
-- 404 if it is not available (e.g. it could not be downloaded, or was invalid)
-- 200 with the JSON content. Note that this must be the original content with the expected hash, not a re-rendering of the original.
getPoolOfflineMetadata
    :: DataLayer
    -> PoolId
    -> PoolMetadataHash
    -> Handler ((Headers '[Header "Cache-Control" Text] (ApiResult DBFail PoolMetadataRaw)))
getPoolOfflineMetadata dataLayer poolId poolHash = fmap (addHeader $ cacheControlHeader NoCache) . convertIOToHandler $ do

    let checkDelistedPool = dlCheckDelistedPool dataLayer
    isDelisted <- checkDelistedPool poolId

    -- When it is delisted, return 403. We don't need any more info.
    when (isDelisted) $
        throwIO err403

    let checkRetiredPool = dlCheckRetiredPool dataLayer
    retiredPoolId <- checkRetiredPool poolId

    -- When that pool id is retired, return 404.
    when (isRight retiredPoolId) $
        throwIO err404

    let dbGetPoolMetadata = dlGetPoolMetadata dataLayer
    poolRecord <- dbGetPoolMetadata poolId poolHash

    case poolRecord of
        -- We return 404 when the hash is not found.
        Left _err -> throwIO err404
        Right (tickerName, poolMetadata) -> do
            let checkReservedTicker = dlCheckReservedTicker dataLayer

            -- We now check whether the reserved ticker name has been reserved for the specific
            -- pool hash.
            reservedTicker <- checkReservedTicker tickerName poolHash
            case reservedTicker of
                Nothing -> return . ApiResult . Right $ poolMetadata
                Just _foundReservedTicker -> throwIO err404

-- |Simple health status, there are ideas for improvement.
getHealthStatus :: Handler (ApiResult DBFail HealthStatus)
getHealthStatus = return . ApiResult . Right $
    HealthStatus
        { hsStatus = "OK"
        , hsVersion = toS $ showVersion version
        }

-- |Get all reserved tickers.
getReservedTickers :: DataLayer -> Handler (ApiResult DBFail [UniqueTicker])
getReservedTickers dataLayer = convertIOToHandler $ do

    let getReservedTickers' = dlGetReservedTickers dataLayer
    reservedTickers <- getReservedTickers'

    let uniqueTickers = map UniqueTicker reservedTickers

    return . ApiResult . Right $ uniqueTickers

-- |Get all delisted pools
getDelistedPools :: DataLayer -> Handler (ApiResult DBFail [PoolId])
getDelistedPools dataLayer = convertIOToHandler $ do

    let getAllDelisted = dlGetDelistedPools dataLayer
    allDelistedPools <- getAllDelisted

    return . ApiResult . Right $ allDelistedPools

#ifdef DISABLE_BASIC_AUTH
delistPool :: DataLayer -> PoolId -> Handler (ApiResult DBFail PoolId)
delistPool dataLayer poolId = delistPool' dataLayer poolId
#else
delistPool :: DataLayer -> User -> PoolId -> Handler (ApiResult DBFail PoolId)
delistPool dataLayer _user poolId = delistPool' dataLayer poolId
#endif

-- |General delist pool.
delistPool' :: DataLayer -> PoolId -> Handler (ApiResult DBFail PoolId)
delistPool' dataLayer poolId = convertIOToHandler $ do

    let addDelistedPool = dlAddDelistedPool dataLayer
    delistedPoolE <- addDelistedPool poolId

    case delistedPoolE of
        Left dbFail   -> throwDBFailException dbFail
        Right poolId' -> return . ApiResult . Right $ poolId'

#ifdef DISABLE_BASIC_AUTH
enlistPool :: DataLayer -> PoolId -> Handler (ApiResult DBFail PoolId)
enlistPool dataLayer poolId = enlistPool' dataLayer poolId
#else
enlistPool :: DataLayer -> User -> PoolId -> Handler (ApiResult DBFail PoolId)
enlistPool dataLayer _user poolId = enlistPool' dataLayer poolId
#endif

-- |General enlist pool function.
enlistPool' :: DataLayer -> PoolId -> Handler (ApiResult DBFail PoolId)
enlistPool' dataLayer poolId = convertIOToHandler $ do

    let removeDelistedPool = dlRemoveDelistedPool dataLayer
    delistedPool' <- removeDelistedPool poolId

    case delistedPool' of
        Left _err     -> throwIO err404
        Right poolId' -> return . ApiResult . Right $ poolId'

getPoolErrorAPI :: DataLayer -> PoolId -> Maybe TimeStringFormat -> Handler (ApiResult DBFail [PoolFetchError])
getPoolErrorAPI dataLayer poolId mTimeInt = convertIOToHandler $ do

    let getFetchErrors = dlGetFetchErrors dataLayer

    -- Unless the user defines the date from which he wants to display the errors,
    -- all the errors from the past day will be shown. We don't want to overwhelm
    -- the operators.
    fetchErrors <- case mTimeInt of
        Nothing -> do
            utcDayAgo <- getUTCTimeDayAgo
            getFetchErrors poolId (Just utcDayAgo)

        Just (TimeStringFormat time) -> getFetchErrors poolId (Just time)

    return . ApiResult $ fetchErrors
  where
    getUTCTimeDayAgo :: IO UTCTime
    getUTCTimeDayAgo =
        addUTCTime (-nominalDay) <$> getCurrentTime

getRetiredPools :: DataLayer -> Handler (ApiResult DBFail [PoolId])
getRetiredPools dataLayer = convertIOToHandler $ do

    let getRetiredPools' = dlGetRetiredPools dataLayer
    retiredPools <- getRetiredPools'

    return . ApiResult $ map (fmap fst) retiredPools

checkPool :: DataLayer -> PoolId -> Handler (ApiResult DBFail PoolId)
checkPool dataLayer poolId = convertIOToHandler $ do

    let getPool = dlGetPool dataLayer
    existingPoolId <- getPool poolId

    return . ApiResult $ existingPoolId

addTicker :: DataLayer -> TickerName -> PoolMetadataHash -> Handler (ApiResult DBFail TickerName)
addTicker dataLayer tickerName poolMetadataHash = convertIOToHandler $ do

    let addReservedTicker = dlAddReservedTicker dataLayer
    reservedTickerE <- addReservedTicker tickerName poolMetadataHash

    case reservedTickerE of
        Left dbFail           -> throwDBFailException dbFail
        Right _reservedTicker -> return . ApiResult . Right $ tickerName

#ifdef DISABLE_BASIC_AUTH
fetchPolicies :: DataLayer -> SmashURL -> Handler (ApiResult DBFail PolicyResult)
fetchPolicies dataLayer smashURL = fetchPolicies' dataLayer smashURL
#else
fetchPolicies :: DataLayer -> User -> SmashURL -> Handler (ApiResult DBFail PolicyResult)
fetchPolicies dataLayer _user smashURL = fetchPolicies' dataLayer smashURL
#endif

-- |General fetch policies function.
fetchPolicies' :: DataLayer -> SmashURL -> Handler (ApiResult DBFail PolicyResult)
fetchPolicies' dataLayer smashURL = convertIOToHandler $ do

    -- Fetch from the remote SMASH server.
    policyResult <- httpClientFetchPolicies smashURL

    let delistedPools =
            case policyResult of
                Left httpClientErr -> panic $ renderHttpClientError httpClientErr
                Right policyResult' -> prDelistedPools policyResult'

    -- Clear the database
    let getDelistedPools' = dlGetDelistedPools dataLayer
    existingDelistedPools <- getDelistedPools'

    let removeDelistedPool = dlRemoveDelistedPool dataLayer
    _ <- mapM removeDelistedPool existingDelistedPools

    let addDelistedPool = dlAddDelistedPool dataLayer
    _newDelistedPools <- mapM addDelistedPool delistedPools

    -- Horrible.
    case policyResult of
        Left httpClientErr -> return . ApiResult . Left . UnknownError $ renderHttpClientError httpClientErr
        Right policyResult' -> return . ApiResult . Right $ policyResult'

#ifdef TESTING_MODE
retirePool :: DataLayer -> PoolIdBlockNumber -> Handler (ApiResult DBFail PoolId)
retirePool dataLayer (PoolIdBlockNumber poolId blockNo) = convertIOToHandler $ do

    let addRetiredPool = dlAddRetiredPool dataLayer
    retiredPoolId <- addRetiredPool poolId blockNo

    return . ApiResult $ retiredPoolId

addPool :: DataLayer -> PoolId -> PoolMetadataHash -> PoolMetadataRaw -> Handler (ApiResult DBFail PoolId)
addPool dataLayer poolId poolHash poolMetadataRaw = convertIOToHandler $ do

    poolMetadataE <- runPoolInsertion dataLayer poolMetadataRaw poolId poolHash

    case poolMetadataE of
        Left dbFail         -> throwDBFailException dbFail
        Right _poolMetadata -> return . ApiResult . Right $ poolId

runPoolInsertion :: DataLayer -> PoolMetadataRaw -> PoolId -> PoolMetadataHash -> IO (Either DBFail PoolMetadataRaw)
runPoolInsertion dataLayer poolMetadataRaw poolId poolHash = do

    decodedMetadata <-  case (eitherDecode' . BL.fromStrict . encodeUtf8 . getPoolMetadata $ poolMetadataRaw) of
                            Left err     -> panic $ toS err
                            Right result -> return result

    let addPoolMetadata = dlAddPoolMetadata dataLayer

    addPoolMetadata Nothing poolId poolHash poolMetadataRaw (pomTicker decodedMetadata)
#endif

