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

import           Data.Aeson
import           Data.Swagger             (Info (..), Swagger (..),
                                           ToParamSchema (..), ToSchema (..),
                                           URL (..))

import           Network.Wai
import           Network.Wai.Handler.Warp

import           Servant
import           Servant.Swagger

-- A data type we use to store user credentials.
data ApplicationUser = ApplicationUser
    { username :: !Text
    , password :: !Text
    } deriving (Eq, Show, Generic)

instance ToJSON ApplicationUser
instance FromJSON ApplicationUser

-- A list of users we use.
newtype ApplicationUsers = ApplicationUsers [ApplicationUser]
    deriving (Eq, Show, Generic)

instance ToJSON ApplicationUsers
instance FromJSON ApplicationUsers

-- | A user we'll grab from the database when we authenticate someone
newtype User = User { userName :: Text }
  deriving (Eq, Show)

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

-- | A list of users with very original passwords.
stubbedApplicationUsers :: ApplicationUsers
stubbedApplicationUsers = ApplicationUsers [ApplicationUser "ksaric" "cirask"]

-- | We need to supply our handlers with the right Context.
basicAuthServerContext :: ApplicationUsers -> Context (BasicAuthCheck User ': '[])
basicAuthServerContext applicationUsers = (authCheck applicationUsers) :. EmptyContext
  where
    -- | 'BasicAuthCheck' holds the handler we'll use to verify a username and password.
    authCheck :: ApplicationUsers -> BasicAuthCheck User
    authCheck (ApplicationUsers applicationUsers') =

        let check :: BasicAuthData -> IO (BasicAuthResult User)
            check (BasicAuthData username password) =
                if (ApplicationUser usernameText passwordText) `elem` applicationUsers'
                    then pure (Authorized (User usernameText))
                    else pure Unauthorized
              where
                usernameText = decodeUtf8 username
                passwordText = decodeUtf8 password

        in BasicAuthCheck check


-- | Natural transformation from @IO@ to @Handler@.
convertIOToHandler :: IO a -> Handler a
convertIOToHandler = Handler . ExceptT . try

-- | Combined server of a Smash service with Swagger documentation.
server :: Configuration -> DataLayer -> Server API --Server SmashAPI
server configuration dataLayer =
         return todoSwagger
    :<|> getPoolOfflineMetadata
    :<|> postBlacklistPool

postBlacklistPool :: User -> BlacklistPool -> Handler PoolOfflineMetadata
postBlacklistPool user blacklistPool = convertIOToHandler $ do
    putTextLn $ show blacklistPool
    return examplePoolOfflineMetadata

-- throwError err404
getPoolOfflineMetadata :: PoolHash -> Handler PoolOfflineMetadata
getPoolOfflineMetadata poolHash = convertIOToHandler $ do
    putTextLn $ show poolHash
    return examplePoolOfflineMetadata


-- | The basic @Configuration@.
data Configuration = Configuration
    { cPortNumber :: !Word
    } deriving (Eq, Show)

stubbedConfiguration :: Configuration
stubbedConfiguration = Configuration 3100

data DataLayerError
    = PoolHashNotFound !PoolHash
    deriving (Eq, Show)

-- | This is the data layer for the DB.
data DataLayer = DataLayer
    { dlGetPoolHash :: PoolHash -> Either DataLayerError PoolOfflineMetadata
    }

-- | Simple stubbed @DataLayer@ for an example.
stubbedDataLayer :: DataLayer
stubbedDataLayer = DataLayer
    { dlGetPoolHash = \_ -> Right examplePoolOfflineMetadata
    }

examplePoolOfflineMetadata :: PoolOfflineMetadata
examplePoolOfflineMetadata =
    PoolOfflineMetadata
        (PoolName "TestPool")
        (PoolDescription "This is a pool for testing")
        (PoolTicker "testp")
        (PoolHomepage "https://iohk.io")

--   "name":{
--      "type":"string",
--      "minLength":1,
--      "maxLength":50
--   },
--   "description":{
--      "type":"string",
--      "minLength":1,
--      "maxLength":255
--   },
--   "ticker":{
--      "type":"string",
--      "minLength":3,
--      "maxLength":5,
--      "pattern":"^[A-Z0-9]{3,5}$"
--   },
--   "homepage":{
--      "type":"string",
--      "format":"uri",
--      "pattern":"^https://"
--   },

-- | Here for checking the validity of the data type.
--isValidPoolOfflineMetadata :: PoolOfflineMetadata -> Bool
--isValidPoolOfflineMetadata poolOfflineMetadata =
--    poolOfflineMetadata
-- TODO(KS): Validation!?

newtype BlacklistPool = BlacklistPool
    { blacklistPool :: Text
    } deriving (Eq, Show, Generic)

instance FromJSON BlacklistPool
instance ToJSON BlacklistPool

instance ToSchema BlacklistPool

-- | Submissions are identified by the subject's Bech32-encoded Ed25519 public key (all lowercase).
-- ed25519_pk1z2ffur59cq7t806nc9y2g64wa60pg5m6e9cmrhxz9phppaxk5d4sn8nsqg
newtype PoolHash = PoolHash
    { getPoolHash :: Text
    } deriving (Eq, Show, Generic)

instance ToParamSchema PoolHash

-- TODO(KS): Temporarily, validation!?
instance FromHttpApiData PoolHash where
    parseUrlPiece poolHashText =
        if (isPrefixOf "ed25519_" (toS poolHashText))
            then Right $ PoolHash poolHashText
            else Left "PoolHash not starting with 'ed25519_'!"

newtype PoolName = PoolName
    { getPoolName :: Text
    } deriving (Eq, Show, Generic)

instance ToSchema PoolName

newtype PoolDescription = PoolDescription
    { getPoolDescription :: Text
    } deriving (Eq, Show, Generic)

instance ToSchema PoolDescription

newtype PoolTicker = PoolTicker
    { getPoolTicker :: Text
    } deriving (Eq, Show, Generic)

instance ToSchema PoolTicker

newtype PoolHomepage = PoolHomepage
    { getPoolHomepage :: Text
    } deriving (Eq, Show, Generic)

instance ToSchema PoolHomepage

data PoolOfflineMetadata = PoolOfflineMetadata
    { name        :: !PoolName
    , description :: !PoolDescription
    , ticker      :: !PoolTicker
    , homepage    :: !PoolHomepage
    } deriving (Eq, Show, Generic)

-- Required instances
instance FromJSON PoolOfflineMetadata where
    parseJSON = withObject "poolOfflineMetadata" $ \o -> do
        name'           <- o .: "name"
        description'    <- o .: "description"
        ticker'         <- o .: "ticker"
        homepage'       <- o .: "homepage"

        return $ PoolOfflineMetadata
            { name          = PoolName name'
            , description   = PoolDescription description'
            , ticker        = PoolTicker ticker'
            , homepage      = PoolHomepage homepage'
            }

instance ToJSON PoolOfflineMetadata where
    toJSON (PoolOfflineMetadata name' description' ticker' homepage') =
        object
            [ "name"            .= getPoolName name'
            , "description"     .= getPoolDescription description'
            , "ticker"          .= getPoolTicker ticker'
            , "homepage"        .= getPoolHomepage homepage'
            ]

--instance ToParamSchema PoolOfflineMetadata
instance ToSchema PoolOfflineMetadata

-- For now, we just ignore the @BasicAuth@ definition.
instance (HasSwagger api) => HasSwagger (BasicAuth name typo :> api) where
    toSwagger _ = toSwagger (Proxy :: Proxy api)

