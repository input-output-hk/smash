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
    ) where

import           Cardano.Prelude hiding (Handler)

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
type OfflineMetadataAPI = "api" :> "v1" :> "metadata" :> Capture "hash" PoolHash :> ApiRes Get PoolMetadataWrapped

-- POST api/v1/delist
#ifdef DISABLE_BASIC_AUTH
type DelistPoolAPI = "api" :> "v1" :> "delist" :> ReqBody '[JSON] DelistPoolHash :> ApiRes Patch DelistPoolHash
#else
-- The basic auth.
type BasicAuthURL = BasicAuth "smash" User
type DelistPoolAPI = BasicAuthURL :> "api" :> "v1" :> "delist" :> ReqBody '[JSON] DelistPoolHash :> ApiRes Patch DelistPoolHash
#endif

type SmashAPI = OfflineMetadataAPI :<|> DelistPoolAPI

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

-- 403 if it is delisted
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
runPoolInsertion :: FilePath -> Text -> IO (Either DBFail Text)
runPoolInsertion poolMetadataJsonPath poolHash = do
    putTextLn $ "Inserting pool! " <> (toS poolMetadataJsonPath) <> " " <> poolHash

    let dataLayer :: DataLayer
        dataLayer = postgresqlDataLayer

    --PoolHash -> ByteString -> IO (Either DBFail PoolHash)
    poolMetadataJson <- readFile poolMetadataJsonPath

    (dlAddPoolMetadata dataLayer) (PoolHash poolHash) poolMetadataJson

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
    :<|>    postDelistPool dataLayer


#ifdef DISABLE_BASIC_AUTH
postDelistPool :: DataLayer -> DelistPoolHash -> Handler (ApiResult DBFail DelistPoolHash)
postDelistPool dataLayer delistPoolHash = convertIOToHandler $ do

    let addDelistedPool = dlAddDelistedPool dataLayer
    delistedPool' <- addDelistedPool delistPoolHash

    return . ApiResult $ delistedPool'
#else
postDelistPool :: DataLayer -> User -> DelistPoolHash -> Handler (ApiResult DBFail DelistPoolHash)
postDelistPool dataLayer user delistPoolHash = convertIOToHandler $ do

    let addDelistedPool = dlAddDelistedPool dataLayer
    delistedPool' <- addDelistedPool delistPoolHash

    return . ApiResult $ delistedPool'
#endif

-- throwError err404
getPoolOfflineMetadata :: DataLayer -> PoolHash -> Handler (ApiResult DBFail PoolMetadataWrapped)
getPoolOfflineMetadata dataLayer poolHash = convertIOToHandler $ do

    let delistPoolHash = DelistPoolHash $ getPoolHash poolHash

    let checkDelistedPool = dlCheckDelistedPool dataLayer
    isDelisted <- checkDelistedPool delistPoolHash

    -- When it is delisted, return 403. We don't need any more info.
    when (isDelisted) $
        throwIO err403

    let getPoolMetadataSimple = dlGetPoolMetadata dataLayer
    poolMetadata <- getPoolMetadataSimple poolHash

    -- We return 404 when the hash is not found.
    case poolMetadata of
        Left err -> throwIO err404
        Right value -> return . ApiResult $ PoolMetadataWrapped <$> poolMetadata

-- | Here for checking the validity of the data type.
--isValidPoolOfflineMetadata :: PoolOfflineMetadata -> Bool
--isValidPoolOfflineMetadata poolOfflineMetadata =
--    poolOfflineMetadata
-- TODO(KS): Validation!?

-- For now, we just ignore the @BasicAuth@ definition.
instance (HasSwagger api) => HasSwagger (BasicAuth name typo :> api) where
    toSwagger _ = toSwagger (Proxy :: Proxy api)

