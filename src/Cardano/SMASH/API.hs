{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}

module Cardano.SMASH.API
    ( API
    , fullAPI
    , smashApi
    ) where

import           Cardano.Prelude

import           Data.Swagger        (Swagger (..))

import           Servant             ((:<|>) (..), (:>))
import           Servant             (BasicAuth, Capture, Get, Header, Headers,
                                      JSON, Patch, QueryParam, ReqBody)

import           Servant.Swagger     (HasSwagger (..))

import           Cardano.SMASH.DB    (DBFail)
import           Cardano.SMASH.Types (ApiResult, HealthStatus, PoolFetchError,
                                      PoolId, PoolMetadataHash,
                                      PoolMetadataWrapped, TimeStringFormat,
                                      User)

-- |For api versioning.
type APIVersion = "v1"

-- | Shortcut for common api result types.
type ApiRes verb a = verb '[JSON] (ApiResult DBFail a)

-- The basic auth.
type BasicAuthURL = BasicAuth "smash" User

-- GET api/v1/status
type HealthStatusAPI = "api" :> APIVersion :> "status" :> ApiRes Get HealthStatus

-- GET api/v1/metadata/{hash}
type OfflineMetadataAPI = "api" :> APIVersion :> "metadata" :> Capture "id" PoolId :> Capture "hash" PoolMetadataHash :> Get '[JSON] (Headers '[Header "Cache" Text] (ApiResult DBFail PoolMetadataWrapped))

-- GET api/v1/delisted
type DelistedPoolsAPI = "api" :> APIVersion :> "delisted" :> ApiRes Get [PoolId]

-- GET api/v1/errors
type FetchPoolErrorAPI = "api" :> APIVersion :> "errors" :> Capture "poolId" PoolId :> QueryParam "fromDate" TimeStringFormat :> ApiRes Get [PoolFetchError]

#ifdef DISABLE_BASIC_AUTH
-- POST api/v1/delist
type DelistPoolAPI = "api" :> APIVersion :> "delist" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId

type EnlistPoolAPI = "api" :> APIVersion :> "enlist" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId
#else
type DelistPoolAPI = BasicAuthURL :> "api" :> APIVersion :> "delist" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId

type EnlistPoolAPI = BasicAuthURL :> "api" :> APIVersion :> "enlist" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId
#endif

type RetiredPoolsAPI = "api" :> APIVersion :> "retired" :> ApiRes Get [PoolId]


-- The full API.
type SmashAPI =  OfflineMetadataAPI
            :<|> HealthStatusAPI
            :<|> DelistedPoolsAPI
            :<|> DelistPoolAPI
            :<|> EnlistPoolAPI
            :<|> FetchPoolErrorAPI
            :<|> RetiredPoolsAPI
#ifdef TESTING_MODE
            :<|> RetirePoolAPI

type RetirePoolAPI = "api" :> APIVersion :> "retired" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId
#endif

-- | API for serving @swagger.json@.
type SwaggerAPI = "swagger.json" :> Get '[JSON] Swagger

-- | Combined API of a Todo service with Swagger documentation.
type API = SwaggerAPI :<|> SmashAPI

fullAPI :: Proxy API
fullAPI = Proxy

-- | Just the @Proxy@ for the API type.
smashApi :: Proxy SmashAPI
smashApi = Proxy

-- For now, we just ignore the @BasicAuth@ definition.
instance (HasSwagger api) => HasSwagger (BasicAuth name typo :> api) where
    toSwagger _ = toSwagger (Proxy :: Proxy api)

