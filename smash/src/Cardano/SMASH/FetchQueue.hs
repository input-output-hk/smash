module Cardano.SMASH.FetchQueue
  ( FetchQueue -- opaque
  , PoolFetchRetry (..)
  , Retry (..)
  , retryCount
  , emptyFetchQueue
  , lenFetchQueue
  , nullFetchQueue
  , insertFetchQueue
  , partitionFetchQueue
  , newRetry
  , nextRetry
  , countedRetry
  ) where


import           Cardano.Prelude

import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Time.Clock.POSIX          (POSIXTime)

import           Cardano.SMASH.DBSync.Db.Schema (PoolMetadataReferenceId)
import           Cardano.SMASH.DBSync.Db.Types  (PoolId, PoolMetadataHash,
                                                 PoolUrl)

import           Cardano.SMASH.FetchQueue.Retry


-- Unfortunately I am way too pressed for time and way too tired to make this less savage.
-- Figuring out how to use an existing priority queue for this task would be more time
-- consuming that writing this from scratch.

newtype FetchQueue = FetchQueue (Map PoolUrl PoolFetchRetry)
    deriving (Show)

data PoolFetchRetry = PoolFetchRetry
  { pfrReferenceId :: !PoolMetadataReferenceId
  , pfrPoolIdWtf   :: !PoolId
  , pfrPoolUrl     :: !PoolUrl
  , pfrPoolMDHash  :: !PoolMetadataHash
  , pfrRetry       :: !Retry
  } deriving (Show)

emptyFetchQueue :: FetchQueue
emptyFetchQueue = FetchQueue mempty

lenFetchQueue :: FetchQueue -> Int
lenFetchQueue (FetchQueue m) = Map.size m

nullFetchQueue :: FetchQueue -> Bool
nullFetchQueue (FetchQueue m) = Map.null m

insertFetchQueue :: [PoolFetchRetry] -> FetchQueue -> FetchQueue
insertFetchQueue xs (FetchQueue mp) =
    FetchQueue $ Map.union mp (Map.fromList $ map build xs)
  where
    build :: PoolFetchRetry -> (PoolUrl, PoolFetchRetry)
    build pfr = (pfrPoolUrl pfr, pfr)

partitionFetchQueue :: FetchQueue -> POSIXTime -> ([PoolFetchRetry], FetchQueue)
partitionFetchQueue (FetchQueue mp) now =
    case Map.partition isRunnable mp of
      (runnable, unrunnable) -> (Map.elems runnable, FetchQueue unrunnable)
  where
    isRunnable :: PoolFetchRetry -> Bool
    isRunnable pfr = retryWhen (pfrRetry pfr) <= now
