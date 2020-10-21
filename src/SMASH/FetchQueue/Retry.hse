{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
module FetchQueue.Retry
  ( Retry (..)
  , newRetry
  , nextRetry
  ) where


import           Cardano.Prelude

import qualified Data.Time.Clock as Time
import           Data.Time.Clock.POSIX (POSIXTime)

import           GHC.Generics (Generic (..))

import           Quiet (Quiet (..))

data Retry = Retry
  { retryWhen :: !POSIXTime
  , retryNext :: !POSIXTime
  , retryCount :: !Word
  } deriving (Eq, Generic)
    deriving Show via (Quiet Retry)

newRetry :: POSIXTime -> Retry
newRetry now =
  Retry
    { retryWhen = now
    , retryNext = now + 60 -- 60 seconds from now
    , retryCount = 0
    }

-- Update a Retry with an exponential (* 3) backoff.
nextRetry :: POSIXTime -> Retry -> Retry
nextRetry now r =
  -- Assuming 'now' is correct, 'retryWhen' and 'retryNext' should always be in the future.
  let udiff = min Time.nominalDay (max 30 (3 * (retryNext r - retryWhen r))) in
  Retry
    { retryWhen = now + udiff
    , retryNext = now + 3 * udiff
    , retryCount = 1 + retryCount r
    }
