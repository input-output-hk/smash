{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Cardano.Db.Error
  ( DBFail (..)
  , renderLookupFail
  ) where

import           Cardano.Prelude

import           Data.Aeson (ToJSON (..), (.=), object, Value (..))

import           Data.ByteString.Char8 (ByteString)

-- | Errors, not exceptions.
data DBFail
  = DbLookupBlockHash !ByteString
  | DbLookupTxMetadataHash !ByteString
  | DbMetaEmpty
  | DbMetaMultipleRows
  | PoolMetadataHashMismatch
  | PoolBlacklisted
  | UnableToEncodePoolMetadataToJSON !Text
  | UnknownError !Text
  deriving (Eq, Show, Generic)

{-

The example we agreed would be:
```
{
    "code": "ERR_4214",
    "description": "You did something wrong."
}
```

-}

instance ToJSON DBFail where
    toJSON failure@(DbLookupBlockHash _hash) =
        object
            [ "code"            .= String "DbLookupBlockHash"
            , "description"     .= String (renderLookupFail failure)
            ]
    toJSON failure@(DbLookupTxMetadataHash _hash) =
        object
            [ "code"            .= String "DbLookupTxMetadataHash"
            , "description"     .= String (renderLookupFail failure)
            ]
    toJSON failure@DbMetaEmpty =
        object
            [ "code"            .= String "DbMetaEmpty"
            , "description"     .= String (renderLookupFail failure)
            ]
    toJSON failure@DbMetaMultipleRows =
        object
            [ "code"            .= String "DbMetaMultipleRows"
            , "description"     .= String (renderLookupFail failure)
            ]
    toJSON failure@(PoolMetadataHashMismatch) =
        object
            [ "code"            .= String "PoolMetadataHashMismatch"
            , "description"     .= String (renderLookupFail failure)
            ]
    toJSON failure@(PoolBlacklisted) =
        object
            [ "code"            .= String "PoolBlacklisted"
            , "description"     .= String (renderLookupFail failure)
            ]
    toJSON failure@(UnableToEncodePoolMetadataToJSON _err) =
        object
            [ "code"            .= String "UnableToEncodePoolMetadataToJSON"
            , "description"     .= String (renderLookupFail failure)
            ]
    toJSON failure@(UnknownError _err) =
        object
            [ "code"            .= String "UnknownError"
            , "description"     .= String (renderLookupFail failure)
            ]


renderLookupFail :: DBFail -> Text
renderLookupFail lf =
  case lf of
    DbLookupBlockHash hash -> "The block hash " <> decodeUtf8 hash <> " is missing from the DB."
    DbLookupTxMetadataHash hash -> "The tx hash " <> decodeUtf8 hash <> " is missing from the DB."
    DbMetaEmpty -> "The metadata table is empty!"
    DbMetaMultipleRows -> "The metadata table contains multiple rows. Error."
    PoolMetadataHashMismatch -> "The pool metadata does not match!"
    PoolBlacklisted -> "The pool has been blacklisted!"
    UnableToEncodePoolMetadataToJSON err -> "Unable to encode the content to JSON. " <> err
    UnknownError text -> "Unknown error. Context: " <> text

