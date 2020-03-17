{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Lib
    ( someFunc
    ) where

import Servant.API

someFunc :: IO ()
someFunc = putStrLn "someFunc"

-- GET /metadata/{hash}
type SmashAPI = "metadata" :> Get '[JSON] PoolOfflineMetadata

-- 403 if it is blacklisted
-- 404 if it is not available (e.g. it could not be downloaded, or was invalid)
-- 200 with the JSON content. Note that this must be the original content with the expected hash, not a re-rendering of the original.

data PoolOfflineMetadata = PoolOfflineMetadata {
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
  name :: String,
  description :: String,
  ticker :: String,
  homepage :: String
}

