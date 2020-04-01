{-# LANGUAGE DeriveGeneric  #-}

module Types
    ( ApplicationUser (..)
    , ApplicationUsers
    , stubbedApplicationUsers
    , User
    , UserValidity (..)
    , checkIfUserValid
    -- * Pool info
    , BlacklistPool
    , PoolHash
    , createPoolHash
    -- * Pool offline metadata
    , PoolName (..)
    , PoolDescription (..)
    , PoolTicker (..)
    , PoolHomepage (..)
    , PoolOfflineMetadata
    , createPoolOfflineMetadata
    , examplePoolOfflineMetadata
    -- * Pool online data
    , PoolOnlineData
    , PoolOwner
    , PoolPledgeAddress
    , examplePoolOnlineData
    -- * Configuration
    , Configuration (..)
    , defaultConfiguration
    ) where

import           Cardano.Prelude

import           Data.Aeson
import           Data.Swagger    (ToParamSchema (..), ToSchema (..))

import           Servant         (FromHttpApiData (..))

-- | The basic @Configuration@.
data Configuration = Configuration
    { cPortNumber :: !Int
    } deriving (Eq, Show)

defaultConfiguration :: Configuration
defaultConfiguration = Configuration 3100

-- | A list of users with very original passwords.
stubbedApplicationUsers :: ApplicationUsers
stubbedApplicationUsers = ApplicationUsers [ApplicationUser "ksaric" "cirask"]

examplePoolOfflineMetadata :: PoolOfflineMetadata
examplePoolOfflineMetadata =
    PoolOfflineMetadata
        (PoolName "TestPool")
        (PoolDescription "This is a pool for testing")
        (PoolTicker "testp")
        (PoolHomepage "https://iohk.io")

examplePoolOnlineData :: PoolOnlineData
examplePoolOnlineData =
    PoolOnlineData
        (PoolOwner "AAAAC3NzaC1lZDI1NTE5AAAAIKFx4CnxqX9mCaUeqp/4EI1+Ly9SfL23/Uxd0Ieegspc")
        (PoolPledgeAddress "e8080fd3b5b5c9fcd62eb9cccbef9892dd74dacf62d79a9e9e67a79afa3b1207")

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

-- | This we can leak.
data UserValidity
    = UserValid !User
    | UserInvalid
    deriving (Eq, Show)

-- | 'BasicAuthCheck' holds the handler we'll use to verify a username and password.
checkIfUserValid :: ApplicationUsers -> ApplicationUser -> UserValidity
checkIfUserValid (ApplicationUsers applicationUsers) applicationUser@(ApplicationUser usernameText _) =
    if applicationUser `elem` applicationUsers
        then (UserValid (User usernameText))
        else UserInvalid

newtype BlacklistPool = BlacklistPool
    { blacklistPool :: Text
    } deriving (Eq, Show, Generic)

instance FromJSON BlacklistPool
instance ToJSON BlacklistPool

instance ToSchema BlacklistPool

-- | We use base64 encoding here.
-- Submissions are identified by the subject's Bech32-encoded Ed25519 public key (all lowercase).
-- An Ed25519 public key is a 64-byte string. We'll typically show such string in base16.
-- base64 is fine too, more concise. But bech32 is definitely overkill here.
-- This might be a synonym for @PoolOwner@.
newtype PoolHash = PoolHash
    { getPoolHash :: Text
    } deriving (Eq, Show, Ord, Generic)

instance ToParamSchema PoolHash

-- | Should be an @Either@.
createPoolHash :: Text -> PoolHash
createPoolHash hash = PoolHash hash

-- TODO(KS): Temporarily, validation!?
instance FromHttpApiData PoolHash where
    parseUrlPiece poolHashText = Right $ PoolHash poolHashText

--        if (isPrefixOf "ed25519_" (toS poolHashText))
--            then Right $ PoolHash poolHashText
--            else Left "PoolHash not starting with 'ed25519_'!"

newtype PoolName = PoolName
    { getPoolName :: Text
    } deriving (Eq, Show, Ord, Generic)

instance ToSchema PoolName

newtype PoolDescription = PoolDescription
    { getPoolDescription :: Text
    } deriving (Eq, Show, Ord, Generic)

instance ToSchema PoolDescription

newtype PoolTicker = PoolTicker
    { getPoolTicker :: Text
    } deriving (Eq, Show, Ord, Generic)

instance ToSchema PoolTicker

newtype PoolHomepage = PoolHomepage
    { getPoolHomepage :: Text
    } deriving (Eq, Show, Ord, Generic)

instance ToSchema PoolHomepage

-- | The bit of the pool data off the chain.
data PoolOfflineMetadata = PoolOfflineMetadata
    { pomName           :: !PoolName
    , pomDescription    :: !PoolDescription
    , pomTicker         :: !PoolTicker
    , pomHomepage       :: !PoolHomepage
    } deriving (Eq, Show, Ord, Generic)

-- | Smart constructor, just adding one more layer of indirection.
createPoolOfflineMetadata
    :: PoolName
    -> PoolDescription
    -> PoolTicker
    -> PoolHomepage
    -> PoolOfflineMetadata
createPoolOfflineMetadata = PoolOfflineMetadata

newtype PoolOwner = PoolOwner
    { getPoolOwner :: Text
    } deriving (Eq, Show, Ord, Generic)

newtype PoolPledgeAddress = PoolPledgeAddress
    { getPoolPledgeAddress :: Text
    } deriving (Eq, Show, Ord, Generic)

-- | The bit of the pool data on the chain.
-- This doesn't leave the internal database.
data PoolOnlineData = PoolOnlineData
    { podOwner          :: !PoolOwner
    , podPledgeAddress  :: !PoolPledgeAddress
    } deriving (Eq, Show, Ord, Generic)

-- Required instances
instance FromJSON PoolOfflineMetadata where
    parseJSON = withObject "poolOfflineMetadata" $ \o -> do
        name'           <- o .: "name"
        description'    <- o .: "description"
        ticker'         <- o .: "ticker"
        homepage'       <- o .: "homepage"

        return $ PoolOfflineMetadata
            { pomName           = PoolName name'
            , pomDescription    = PoolDescription description'
            , pomTicker         = PoolTicker ticker'
            , pomHomepage       = PoolHomepage homepage'
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

