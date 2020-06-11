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
  | TxMetadataHashMismatch
  | UnknownError !Text
  deriving (Eq, Show, Generic)

instance ToJSON DBFail where
    toJSON (DbLookupTxMetadataHash hash) =
        object
            [ "error"           .= String "DbLookupTxMetadataHash"
            , "extraInfo"       .= decodeUtf8 hash
            ]
--instance FromJSON DBFail

renderLookupFail :: DBFail -> Text
renderLookupFail lf =
  case lf of
    DbLookupTxMetadataHash h -> "Tx metadata hash " <> Text.decodeUtf8 h
    TxMetadataHashMismatch -> "Tx metadata hash mismatch"
    UnknownError text -> "Unknown error. Context: " <> text


textShow :: Show a => a -> Text
textShow = Text.pack . show
