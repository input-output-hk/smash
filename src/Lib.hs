{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

module Lib
    ( Configuration (..)
    , DBFail (..) -- We need to see errors clearly outside
    , defaultConfiguration
    , runApp
    , runAppStubbed
    , runPoolInsertion
    , runTickerNameInsertion
    ) where

import           Cardano.Prelude             hiding (Handler)

import           Data.Aeson                  (eitherDecode')
import qualified Data.ByteString.Lazy        as BL
import           Data.IORef                  (newIORef)
import           Data.Swagger                (Info (..), Swagger (..))

import           Network.Wai.Handler.Warp    (defaultSettings, runSettings,
                                              setBeforeMainLoop, setPort)

import           Servant                     ((:<|>) (..), (:>))
import           Servant                     (Application, BasicAuth,
                                              BasicAuthCheck (..),
                                              BasicAuthData (..),
                                              BasicAuthResult (..), Capture,
                                              Context (..), Get, Handler (..),
                                              HasServer (..), Header, Headers,
                                              JSON, Patch, QueryParam, ReqBody,
                                              Server, ServerT, err403, err404,
                                              serveWithContext)
import           Servant.API.ResponseHeaders (addHeader)
import           Servant.Swagger

import           DB
import           Types


-- | Shortcut for common api result types.
type ApiRes verb a = verb '[JSON] (ApiResult DBFail a)

-- GET api/v1/metadata/{hash}
type OfflineMetadataAPI = "api" :> "v1" :> "metadata" :> Capture "id" PoolId :> Capture "hash" PoolMetadataHash :> Get '[JSON] (Headers '[Header "Cache" Text] (ApiResult DBFail PoolMetadataWrapped))

-- GET api/v1/delisted
type DelistedPoolsAPI = "api" :> "v1" :> "delisted" :> ApiRes Get [PoolId]

#ifdef DISABLE_BASIC_AUTH
-- POST api/v1/delist
type DelistPoolAPI = "api" :> "v1" :> "delist" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId

type EnlistPoolAPI = "api" :> "v1" :> "enlist" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId

type FetchPoolErrorAPI = "api" :> "v1" :> "errors" :> QueryParam "poolId" PoolId :> ApiRes Get [PoolFetchError]
#else
-- The basic auth.
type BasicAuthURL = BasicAuth "smash" User

type DelistPoolAPI = BasicAuthURL :> "api" :> "v1" :> "delist" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId

type EnlistPoolAPI = BasicAuthURL :> "api" :> "v1" :> "enlist" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId

type FetchPoolErrorAPI = BasicAuthURL :> "api" :> "v1" :> "errors" :> QueryParam "poolId" PoolId :> ApiRes Get [PoolFetchError]
#endif

type RetiredPoolsAPI = "api" :> "v1" :> "retired" :> ApiRes Get [PoolId]


-- The full API.
type SmashAPI =  OfflineMetadataAPI
            :<|> DelistedPoolsAPI
            :<|> DelistPoolAPI
            :<|> EnlistPoolAPI
            :<|> FetchPoolErrorAPI
            :<|> RetiredPoolsAPI
#ifdef TESTING_MODE
            :<|> RetirePoolAPI

type RetirePoolAPI = "api" :> "v1" :> "retired" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId
#endif


-- | Swagger spec for Todo API.
todoSwagger :: Swagger
todoSwagger =
    let swaggerDefinition = toSwagger smashApi
    in swaggerDefinition {_swaggerInfo = swaggerInfo}
  where
    -- (Licence (Just "APACHE2" "https://github.com/input-output-hk/smash/blob/master/LICENSE"))
    swaggerInfo :: Info
    swaggerInfo = Info
        "Smash"
        (Just "Stakepool Metadata Aggregation Server")
        Nothing
        Nothing
        Nothing
        "1.1.0"

-- | API for serving @swagger.json@.
type SwaggerAPI = "swagger.json" :> Get '[JSON] Swagger

-- | Combined API of a Todo service with Swagger documentation.
type API = SwaggerAPI :<|> SmashAPI

fullAPI :: Proxy API
fullAPI = Proxy

-- | Just the @Proxy@ for the API type.
smashApi :: Proxy SmashAPI
smashApi = Proxy

runApp :: Configuration -> IO ()
runApp configuration = do
    let port = cPortNumber configuration
    let settings =
          setPort port $
          setBeforeMainLoop (hPutStrLn stderr ("listening on port " ++ show port)) $
          defaultSettings

    runSettings settings =<< mkApp configuration

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

    ioDataMap        <- newIORef stubbedInitialDataMap
    ioDelistedPools  <- newIORef stubbedDelistedPools

    let dataLayer :: DataLayer
        dataLayer = stubbedDataLayer ioDataMap ioDelistedPools

    return $ serveWithContext
        fullAPI
        (basicAuthServerContext stubbedApplicationUsers)
        (server configuration dataLayer)

mkApp :: Configuration -> IO Application
mkApp configuration = do

    let dataLayer :: DataLayer
        dataLayer = postgresqlDataLayer

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
    convertToAppUsers (AdminUser username password) = ApplicationUser username password

--runPoolInsertion poolMetadataJsonPath poolHash
runPoolInsertion :: FilePath -> PoolId -> PoolMetadataHash -> IO (Either DBFail Text)
runPoolInsertion poolMetadataJsonPath poolId poolHash = do
    putTextLn $ "Inserting pool! " <> (toS poolMetadataJsonPath) <> " " <> (show poolId)

    let dataLayer :: DataLayer
        dataLayer = postgresqlDataLayer

    --PoolHash -> ByteString -> IO (Either DBFail PoolHash)
    poolMetadataJson <- readFile poolMetadataJsonPath

    -- Let us try to decode the contents to JSON.
    decodedMetadata <-  case (eitherDecode' $ BL.fromStrict (encodeUtf8 poolMetadataJson)) of
                            Left err     -> panic $ toS err
                            Right result -> return result

    let addPoolMetadata = dlAddPoolMetadata dataLayer

    addPoolMetadata Nothing poolId poolHash poolMetadataJson (pomTicker decodedMetadata)

runTickerNameInsertion :: Text -> PoolMetadataHash -> IO (Either DBFail ReservedTickerId)
runTickerNameInsertion tickerName poolMetadataHash = do

    let dataLayer :: DataLayer
        dataLayer = postgresqlDataLayer

    let addReservedTicker = dlAddReservedTicker dataLayer
    putTextLn $ "Adding reserved ticker '" <> tickerName <> "' with hash: " <> show poolMetadataHash

    addReservedTicker tickerName poolMetadataHash

-- | We need to supply our handlers with the right Context.
basicAuthServerContext :: ApplicationUsers -> Context (BasicAuthCheck User ': '[])
basicAuthServerContext applicationUsers = (authCheck applicationUsers) :. EmptyContext
  where
    -- | 'BasicAuthCheck' holds the handler we'll use to verify a username and password.
    authCheck :: ApplicationUsers -> BasicAuthCheck User
    authCheck applicationUsers' =

        let check' :: BasicAuthData -> IO (BasicAuthResult User)
            check' (BasicAuthData username password) = do
                let usernameText = decodeUtf8 username
                let passwordText = decodeUtf8 password

                let applicationUser  = ApplicationUser usernameText passwordText
                let userAuthValidity = checkIfUserValid applicationUsers' applicationUser

                case userAuthValidity of
                    UserValid user -> pure (Authorized user)
                    UserInvalid    -> pure Unauthorized

        in BasicAuthCheck check'


-- | Natural transformation from @IO@ to @Handler@.
convertIOToHandler :: IO a -> Handler a
convertIOToHandler = Handler . ExceptT . try

-- | Combined server of a Smash service with Swagger documentation.
server :: Configuration -> DataLayer -> Server API
server configuration dataLayer
    =       return todoSwagger
    :<|>    getPoolOfflineMetadata dataLayer
    :<|>    getDelistedPools dataLayer
    :<|>    delistPool dataLayer
    :<|>    enlistPool dataLayer
    :<|>    getPoolErrorAPI dataLayer
    :<|>    getRetiredPools dataLayer
#ifdef TESTING_MODE
    :<|>    retirePool dataLayer
#endif


-- 403 if it is delisted
-- 404 if it is not available (e.g. it could not be downloaded, or was invalid)
-- 200 with the JSON content. Note that this must be the original content with the expected hash, not a re-rendering of the original.
getPoolOfflineMetadata
    :: DataLayer
    -> PoolId
    -> PoolMetadataHash
    -> Handler ((Headers '[Header "Cache" Text] (ApiResult DBFail PoolMetadataWrapped)))
getPoolOfflineMetadata dataLayer poolId poolHash = fmap (addHeader "always") . convertIOToHandler $ do

    let checkDelistedPool = dlCheckDelistedPool dataLayer
    isDelisted <- checkDelistedPool poolId

    -- When it is delisted, return 403. We don't need any more info.
    when (isDelisted) $
        throwIO err403

    let getPoolMetadata = dlGetPoolMetadata dataLayer
    poolRecord <- getPoolMetadata poolId poolHash

    case poolRecord of
        -- We return 404 when the hash is not found.
        Left err -> throwIO err404
        Right (tickerName, poolMetadata) -> do
            let checkReservedTicker = dlCheckReservedTicker dataLayer

            -- We now check whether the reserved ticker name has been reserved for the specific
            -- pool hash.
            reservedTicker <- checkReservedTicker tickerName
            case reservedTicker of
                Nothing -> return . ApiResult . Right $ PoolMetadataWrapped poolMetadata
                Just foundReservedTicker ->
                    if (reservedTickerPoolHash foundReservedTicker) == poolHash
                        then return . ApiResult . Right $ PoolMetadataWrapped poolMetadata
                        else throwIO err404


-- |Get all delisted pools
getDelistedPools :: DataLayer -> Handler (ApiResult DBFail [PoolId])
getDelistedPools dataLayer = convertIOToHandler $ do
    let getAllDelisted = dlGetDelistedPools dataLayer
    allDelistedPools <- getAllDelisted
    return . ApiResult . Right $ allDelistedPools


#ifdef DISABLE_BASIC_AUTH
delistPool :: DataLayer -> PoolId -> Handler (ApiResult DBFail PoolId)
delistPool dataLayer poolId = convertIOToHandler $ do

    let addDelistedPool = dlAddDelistedPool dataLayer
    delistedPool' <- addDelistedPool poolId

    return . ApiResult $ delistedPool'
#else
delistPool :: DataLayer -> User -> PoolId -> Handler (ApiResult DBFail PoolId)
delistPool dataLayer user poolId = convertIOToHandler $ do

    let addDelistedPool = dlAddDelistedPool dataLayer
    delistedPool' <- addDelistedPool poolId

    return . ApiResult $ delistedPool'
#endif


#ifdef DISABLE_BASIC_AUTH
enlistPool :: DataLayer -> PoolId -> Handler (ApiResult DBFail PoolId)
enlistPool dataLayer poolId = convertIOToHandler $ do

    let removeDelistedPool = dlRemoveDelistedPool dataLayer
    delistedPool' <- removeDelistedPool poolId

    case delistedPool' of
        Left err -> throwIO err404
        Right poolId' -> return . ApiResult . Right $ poolId
#else
enlistPool :: DataLayer -> User -> PoolId -> Handler (ApiResult DBFail PoolId)
enlistPool dataLayer user poolId = convertIOToHandler $ do

    let removeDelistedPool = dlRemoveDelistedPool dataLayer
    delistedPool' <- removeDelistedPool poolId

    case delistedPool' of
        Left err -> throwIO err404
        Right poolId' -> return . ApiResult . Right $ poolId'
#endif


#ifdef DISABLE_BASIC_AUTH
getPoolErrorAPI :: DataLayer -> Maybe PoolId -> Handler (ApiResult DBFail [PoolFetchError])
getPoolErrorAPI dataLayer mPoolId = convertIOToHandler $ do

    let getFetchErrors = dlGetFetchErrors dataLayer
    fetchErrors <- getFetchErrors mPoolId

    return . ApiResult $ fetchErrors
#else
getPoolErrorAPI :: DataLayer -> User -> Maybe PoolId -> Handler (ApiResult DBFail [PoolFetchError])
getPoolErrorAPI dataLayer _user mPoolId = convertIOToHandler $ do

    let getFetchErrors = dlGetFetchErrors dataLayer
    fetchErrors <- getFetchErrors mPoolId

    return . ApiResult $ fetchErrors
#endif

getRetiredPools :: DataLayer -> Handler (ApiResult DBFail [PoolId])
getRetiredPools dataLayer = convertIOToHandler $ do
    let getRetiredPools = dlGetRetiredPools dataLayer
    retiredPools <- getRetiredPools
    return . ApiResult $ retiredPools

#ifdef TESTING_MODE
retirePool :: DataLayer -> PoolId -> Handler (ApiResult DBFail PoolId)
retirePool dataLayer poolId = convertIOToHandler $ do
    let addRetiredPool = dlAddRetiredPool dataLayer
    retiredPoolId <- addRetiredPool poolId
    return . ApiResult $ retiredPoolId
#endif

-- For now, we just ignore the @BasicAuth@ definition.
instance (HasSwagger api) => HasSwagger (BasicAuth name typo :> api) where
    toSwagger _ = toSwagger (Proxy :: Proxy api)

