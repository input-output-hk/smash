{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

module Lib
    ( runApp
    ) where

import           Cardano.Prelude

import           Data.Swagger             (Info (..), Swagger (..))

import           Network.Wai.Handler.Warp (defaultSettings, runSettings,
                                           setBeforeMainLoop, setPort)

import           Servant                  ((:<|>) (..), (:>))
import           Servant                  (Application, BasicAuth,
                                           BasicAuthCheck (..),
                                           BasicAuthData (..),
                                           BasicAuthResult (..), Capture,
                                           Context (..), Get, Handler (..),
                                           JSON, Post, ReqBody, Server,
                                           serveWithContext)
import           Servant.Swagger

import           DB
import           Types

-- The basic auth.
type BasicAuthURL = BasicAuth "smash" User

-- GET api/v1/metadata/{hash}
type OfflineMetadataAPI = "api" :> "v1" :> "metadata" :> Capture "hash" PoolHash :> Get '[JSON] PoolOfflineMetadata
-- POST api/v1/blacklist |-> {"blacklistPool" : "pool"}
type BlacklistPoolAPI = BasicAuthURL :> "api" :> "v1" :> "blacklist" :> ReqBody '[JSON] BlacklistPool :> Post '[JSON] PoolOfflineMetadata

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

runApp :: IO ()
runApp = do
    let port = 3000
        settings =
          setPort port $
          setBeforeMainLoop (hPutStrLn stderr ("listening on port " ++ show port)) $
          defaultSettings
    runSettings settings =<< mkApp

mkApp :: IO Application
mkApp = return $ serveWithContext
            fullAPI
            (basicAuthServerContext stubbedApplicationUsers)
            (server stubbedConfiguration stubbedDataLayer)

-- | We need to supply our handlers with the right Context.
basicAuthServerContext :: ApplicationUsers -> Context (BasicAuthCheck User ': '[])
basicAuthServerContext applicationUsers = (authCheck applicationUsers) :. EmptyContext
  where
    -- | 'BasicAuthCheck' holds the handler we'll use to verify a username and password.
    authCheck :: ApplicationUsers -> BasicAuthCheck User
    authCheck applicationUsers' =

        let check :: BasicAuthData -> IO (BasicAuthResult User)
            check (BasicAuthData username password) = do
                let usernameText = decodeUtf8 username
                let passwordText = decodeUtf8 password

                let applicationUser  = ApplicationUser usernameText passwordText
                let userAuthValidity = checkIfUserValid applicationUsers' applicationUser

                case userAuthValidity of
                    UserValid user -> pure (Authorized user)
                    UserInvalid    -> pure Unauthorized

        in BasicAuthCheck check


-- | Natural transformation from @IO@ to @Handler@.
convertIOToHandler :: IO a -> Handler a
convertIOToHandler = Handler . ExceptT . try

-- | Combined server of a Smash service with Swagger documentation.
server :: Configuration -> DataLayer -> Server API --Server SmashAPI
server configuration dataLayer
    =       return todoSwagger
    :<|>    getPoolOfflineMetadata
    :<|>    postBlacklistPool

postBlacklistPool :: User -> BlacklistPool -> Handler PoolOfflineMetadata
postBlacklistPool user blacklistPool = convertIOToHandler $ do
    putTextLn $ show blacklistPool
    return examplePoolOfflineMetadata

-- throwError err404
getPoolOfflineMetadata :: PoolHash -> Handler PoolOfflineMetadata
getPoolOfflineMetadata poolHash = convertIOToHandler $ do
    putTextLn $ show poolHash
    return examplePoolOfflineMetadata

-- | Here for checking the validity of the data type.
--isValidPoolOfflineMetadata :: PoolOfflineMetadata -> Bool
--isValidPoolOfflineMetadata poolOfflineMetadata =
--    poolOfflineMetadata
-- TODO(KS): Validation!?

-- For now, we just ignore the @BasicAuth@ definition.
instance (HasSwagger api) => HasSwagger (BasicAuth name typo :> api) where
    toSwagger _ = toSwagger (Proxy :: Proxy api)

