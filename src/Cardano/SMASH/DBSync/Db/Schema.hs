{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

module Cardano.SMASH.DBSync.Db.Schema where

import           Cardano.Prelude               hiding (Meta)

import           Data.ByteString.Char8         (ByteString)
import           Data.Text                     (Text)
import           Data.Time.Clock               (UTCTime)
import           Data.Word                     (Word64)

-- Do not use explicit imports from this module as the imports can change
-- from version to version due to changes to the TH code in Persistent.
import           Database.Persist.TH

import qualified Cardano.SMASH.DBSync.Db.Types as Types


-- In the schema definition we need to match Haskell types with with the
-- custom type defined in PostgreSQL (via 'DOMAIN' statements). For the
-- time being the Haskell types will be simple Haskell types like
-- 'ByteString' and 'Word64'.

-- We use camelCase here in the Haskell schema definition and 'persistLowerCase'
-- specifies that all the table and column names are converted to lower snake case.

share
  [ mkPersist sqlSettings
  , mkDeleteCascade sqlSettings
  , mkMigrate "migrateCardanoDb"
  ]
  [persistLowerCase|

  -- Schema versioning has three stages to best allow handling of schema migrations.
  --    Stage 1: Set up PostgreSQL data types (using SQL 'DOMAIN' statements).
  --    Stage 2: Persistent generated migrations.
  --    Stage 3: Set up 'VIEW' tables (for use by other languages and applications).
  -- This table should have a single row.
  SchemaVersion
    stageOne Int
    stageTwo Int
    stageThree Int

  -- The table containing pools' on-chain reference to its off-chain metadata.

  PoolMetadataReference
    poolId              Types.PoolId              sqltype=text
    url                 Types.PoolUrl             sqltype=text
    hash                Types.PoolMetadataHash    sqltype=text
    UniquePoolMetadataReference  poolId hash

  -- The table containing the metadata.

  PoolMetadata
    poolId              Types.PoolId              sqltype=text
    tickerName          Types.TickerName          sqltype=text
    hash                Types.PoolMetadataHash    sqltype=text
    metadata            Types.PoolMetadataRaw     sqltype=text
    pmrId               PoolMetadataReferenceId Maybe
    UniquePoolMetadata  poolId hash

  -- The pools themselves (identified by the owner vkey hash)

  Pool
    poolId              PoolId                    sqltype=text
    UniquePoolId poolId

  -- The retired pools.

  RetiredPool
    poolId              Types.PoolId              sqltype=text
    UniqueRetiredPoolId poolId

  -- The pool metadata fetch error. We duplicate the poolId for easy access.

  PoolMetadataFetchError
    fetchTime           UTCTime                   sqltype=timestamp
    poolId              Types.PoolId              sqltype=text
    poolHash            Types.PoolMetadataHash    sqltype=text
    pmrId               PoolMetadataReferenceId
    fetchError          Text
    retryCount          Word                      sqltype=uinteger
    UniquePoolMetadataFetchError fetchTime poolId

  -- We actually need the block table to be able to persist sync data

  Block
    hash                ByteString          sqltype=hash32type
    epochNo             Word64 Maybe        sqltype=uinteger
    slotNo              Word64 Maybe        sqltype=uinteger
    blockNo             Word64 Maybe        sqltype=uinteger
    UniqueBlock         hash

  -- A table containing metadata about the chain. There will probably only ever be one
  -- row in this table.
  Meta
    protocolConst       Word64              -- The block security parameter.
    slotDuration        Word64              -- Slot duration in milliseconds.
                                            -- System start time used to calculate slot time stamps.
                                            -- Use 'sqltype' here to force timestamp without time zone.
    startTime           UTCTime             sqltype=timestamp
    slotsPerEpoch       Word64              -- Number of slots per epoch.
    networkName         Text Maybe
    UniqueMeta          startTime

  -- A table containing a list of delisted pools.
  DelistedPool
    poolId              Types.PoolId        sqltype=text
    UniqueDelistedPool poolId

  -- A table containing a managed list of reserved ticker names.
  -- For now they are grouped under the specific hash of the pool.
  ReservedTicker
    name                Text                    sqltype=text
    poolHash            Types.PoolMetadataHash  sqltype=text
    UniqueReservedTicker name

  -- A table containin a list of administrator users that can be used to access the secure API endpoints.
  -- Yes, we don't have any hash check mechanisms here, if they get to the database, game over anyway.
  AdminUser
    username            Text
    password            Text
    UniqueAdminUser     username

  |]

