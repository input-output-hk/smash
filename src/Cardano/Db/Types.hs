{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}

module Cardano.Db.Types where

import Cardano.Prelude

import Data.ByteString (ByteString)
import Data.Aeson (ToJSON)
import Database.Persist.Class

-- | The stake pool identifier. It is the hash of the stake pool operator's
-- vkey.
--
-- It may be rendered as hex or as bech32 using the @pool@ prefix.
--
newtype PoolId = PoolId { getPoolId :: ByteString }
  deriving stock (Eq, Show, Ord, Generic)
  deriving newtype PersistField

--TODO: instance ToJSON PoolId


-- | The hash of a stake pool's metadata.
--
-- It may be rendered as hex.
--
newtype PoolMetadataHash = PoolMetadataHash { getPoolMetadataHash :: ByteString }
  deriving stock (Eq, Show, Ord, Generic)
  deriving newtype PersistField

--TODO: instance ToJSON PoolMetadataHash


-- | The stake pool metadata. It is JSON format. This type represents it in
-- its raw original form. The hash of this content is the 'PoolMetadataHash'.
--
newtype PoolMetadataRaw = PoolMetadataRaw { getPoolMetadata :: ByteString }
  deriving stock (Eq, Show, Ord, Generic)
  deriving newtype PersistField
