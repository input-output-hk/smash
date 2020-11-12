{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}

module Cardano.SMASH.DBSync.Db.Types where

import Cardano.Prelude

import Data.Aeson (ToJSON (..), FromJSON (..), withObject, object, (.=), (.:))
import Database.Persist.Class

-- | The stake pool identifier. It is the hash of the stake pool operator's
-- vkey.
--
-- It may be rendered as hex or as bech32 using the @pool@ prefix.
--
newtype PoolId = PoolId { getPoolId :: Text }
  deriving stock (Eq, Show, Ord, Generic)
  deriving newtype PersistField

instance ToJSON PoolId where
    toJSON (PoolId poolId) =
        object
            [ "poolId" .= poolId
            ]

instance FromJSON PoolId where
    parseJSON = withObject "PoolId" $ \o -> do
        poolId <- o .: "poolId"
        return $ PoolId poolId

-- | The hash of a stake pool's metadata.
--
-- It may be rendered as hex.
--
newtype PoolMetadataHash = PoolMetadataHash { getPoolMetadataHash :: Text }
  deriving stock (Eq, Show, Ord, Generic)
  deriving newtype PersistField

instance ToJSON PoolMetadataHash
instance FromJSON PoolMetadataHash

-- | The stake pool metadata. It is JSON format. This type represents it in
-- its raw original form. The hash of this content is the 'PoolMetadataHash'.
--
newtype PoolMetadataRaw = PoolMetadataRaw { getPoolMetadata :: Text }
  deriving stock (Eq, Show, Ord, Generic)
  deriving newtype PersistField

-- | The pool url wrapper so we have some additional safety.
newtype PoolUrl = PoolUrl { getPoolUrl :: Text }
  deriving stock (Eq, Show, Ord, Generic)
  deriving newtype PersistField

-- | The ticker name wrapper so we have some additional safety.
newtype TickerName = TickerName { getTickerName :: Text }
  deriving stock (Eq, Show, Ord, Generic)
  deriving newtype PersistField

instance ToJSON TickerName
instance FromJSON TickerName

