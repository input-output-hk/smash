{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

module Lib
    ( Configuration (..)
    , DBFail (..) -- We need to see errors clearly outside
    , defaultConfiguration
    , runApp
    , runAppStubbed
    , runPoolInsertion
    , runTickerNameInsertion
    ) where

import           Cardano.Prelude          hiding (Handler)

import           Data.Aeson               (eitherDecode')
import qualified Data.ByteString.Lazy     as BL
import           Data.IORef               (newIORef)
import           Data.Swagger             (Info (..), Swagger (..))

import           Network.Wai.Handler.Warp (defaultSettings, runSettings,
                                           setBeforeMainLoop, setPort)

import           Servant                  ((:<|>) (..), (:>))
import           Servant                  (Application, BasicAuth,
                                           BasicAuthCheck (..),
                                           BasicAuthData (..),
                                           BasicAuthResult (..), Capture,
                                           Context (..), Get, Handler (..),
                                           JSON, Patch, ReqBody, Server, err403,
                                           err404, serveWithContext)
import           Servant.Swagger

import           DB
import           Types

-- | Shortcut for common api result types.
type ApiRes verb a = verb '[JSON] (ApiResult DBFail a)

-- GET api/v1/metadata/{hash}
type OfflineMetadataAPI = "api" :> "v1" :> "metadata" :> Capture "id" PoolId :> Capture "hash" PoolMetadataHash :> ApiRes Get PoolMetadataWrapped

-- POST api/v1/blacklist
#ifdef DISABLE_BASIC_AUTH
type BlacklistPoolAPI = "api" :> "v1" :> "blacklist" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId
#else
-- The basic auth.
type BasicAuthURL = BasicAuth "smash" User
type BlacklistPoolAPI = BasicAuthURL :> "api" :> "v1" :> "blacklist" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId
#endif

type SmashAPI = OfflineMetadataAPI :<|> BlacklistPoolAPI

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
        "0.0.1"

-- | API for serving @swagger.json@.
type SwaggerAPI = "swagger.json" :> Get '[JSON] Swagger

-- | Combined API of a Todo service with Swagger documentation.
type API = SwaggerAPI :<|> SmashAPI

fullAPI :: Proxy API
fullAPI = Proxy

-- | Just the @Proxy@ for the API type.
smashApi :: Proxy SmashAPI
smashApi = Proxy

-- 403 if it is blacklisted
-- 404 if it is not available (e.g. it could not be downloaded, or was invalid)
-- 200 with the JSON content. Note that this must be the original content with the expected hash, not a re-rendering of the original.

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

    ioDataMap           <- newIORef stubbedInitialDataMap
    ioBlacklistedPools  <- newIORef stubbedBlacklistedPools

    let dataLayer :: DataLayer
        dataLayer = stubbedDataLayer ioDataMap ioBlacklistedPools

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

    addPoolMetadata (panic "runPoolInsertion") poolId poolHash poolMetadataJson (pomTicker decodedMetadata)

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
    :<|>    postBlacklistPool dataLayer

#ifdef DISABLE_BASIC_AUTH
postBlacklistPool :: DataLayer -> PoolId -> Handler (ApiResult DBFail PoolId)
postBlacklistPool dataLayer poolId = convertIOToHandler $ do

    let addBlacklistedPool = dlAddBlacklistedPool dataLayer
    blacklistedPool' <- addBlacklistedPool poolId

    return . ApiResult $ blacklistedPool'
#else
postBlacklistPool :: DataLayer -> User -> PoolId -> Handler (ApiResult DBFail PoolId)
postBlacklistPool dataLayer user poolId = convertIOToHandler $ do

    let addBlacklistedPool = dlAddBlacklistedPool dataLayer
    blacklistedPool' <- addBlacklistedPool poolId

    return . ApiResult $ blacklistedPool'
#endif

-- throwError err404
getPoolOfflineMetadata :: DataLayer -> PoolId -> PoolMetadataHash -> Handler (ApiResult DBFail PoolMetadataWrapped)
getPoolOfflineMetadata dataLayer poolId poolHash = convertIOToHandler $ do

    let checkBlacklistedPool = dlCheckBlacklistedPool dataLayer
    isBlacklisted <- checkBlacklistedPool poolId

    -- When it is blacklisted, return 403. We don't need any more info.
    when (isBlacklisted) $
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

-- For now, we just ignore the @BasicAuth@ definition.
instance (HasSwagger api) => HasSwagger (BasicAuth name typo :> api) where
    toSwagger _ = toSwagger (Proxy :: Proxy api)

