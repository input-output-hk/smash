{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Cardano.Db.Error
  ( DBFail (..)
  , renderLookupFail
  ) where

import           Cardano.Prelude

import           Data.Aeson (ToJSON (..), (.=), object, Value (..))

import           Data.ByteString.Char8 (ByteString)
import qualified Data.Text as Text
import           Data.Text (Text)
import qualified Data.Text.Encoding as Text
import           Data.Word (Word16, Word64)

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
    toJSON (DbLookupTxMetadataHash hash) =
        object
            [ "code"            .= String "DbLookupTxMetadataHash"
            , "description"     .= String ("The hash " <> decodeUtf8 hash <> " is missing from the DB.")
            ]
    toJSON (PoolMetadataHashMismatch) =
        object
            [ "code"            .= String "PoolMetadataHashMismatch"
            , "description"     .= String "The pool metadata does not match!"
            ]
    toJSON (UnableToEncodePoolMetadataToJSON err) =
        object
            [ "code"            .= String "UnableToEncodePoolMetadataToJSON"
            , "description"     .= String ("Unable to encode the content to JSON. " <> err)
            ]
    toJSON (UnknownError err) =
        object
            [ "code"            .= String "UnknownError"
            , "description"     .= String err
            ]


renderLookupFail :: DBFail -> Text
renderLookupFail lf =
  case lf of
    DbLookupTxMetadataHash hash -> "The hash " <> decodeUtf8 hash <> " is missing from the DB."
    PoolMetadataHashMismatch -> "The pool metadata does not match!"
    UnableToEncodePoolMetadataToJSON err -> "Unable to encode the content to JSON. " <> err
    UnknownError text -> "Unknown error. Context: " <> text


textShow :: Show a => a -> Text
textShow = Text.pack . show
