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
  = DbLookupTxMetadataHash !ByteString
  | PoolMetadataHashMismatch
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
    toJSON failure@(DbLookupTxMetadataHash _hash) =
        object
            [ "code"            .= String "DbLookupTxMetadataHash"
            , "description"     .= String (renderLookupFail failure)
            ]
    toJSON failure@(PoolMetadataHashMismatch) =
        object
            [ "code"            .= String "PoolMetadataHashMismatch"
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
    DbLookupTxMetadataHash hash -> "The hash " <> decodeUtf8 hash <> " is missing from the DB."
    PoolMetadataHashMismatch -> "The pool metadata does not match!"
    UnableToEncodePoolMetadataToJSON err -> "Unable to encode the content to JSON. " <> err
    UnknownError text -> "Unknown error. Context: " <> text

