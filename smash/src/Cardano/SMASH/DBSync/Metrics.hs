{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Cardano.SMASH.DBSync.Metrics
  ( Metrics (..)
  , makeMetrics
  , withMetricSetters
  , withMetricsServer
  ) where

import           Cardano.Prelude

import           Cardano.Slotting.Slot (SlotNo (..))

import           Ouroboros.Network.Block (BlockNo (..))

import           System.Metrics.Prometheus.Concurrent.RegistryT (RegistryT (..), registerGauge,
                   runRegistryT, unRegistryT)
import           System.Metrics.Prometheus.Http.Scrape (serveMetricsT)
import           System.Metrics.Prometheus.Metric.Gauge (Gauge)
import qualified System.Metrics.Prometheus.Metric.Gauge as Gauge

-- The metrics we use.
-- Kept as a separate struct and do not put into environment because
-- when we need to test functions using this we need to initialize the
-- whole environment and not just pass in the layer. This shows clearly
-- that it needs to remain a separate parameter passed around where needed.
data MetricSetters = MetricSetters
  { metricsSetNodeBlockHeight :: BlockNo -> IO ()
  , metricsSetDbQueueLength :: Natural -> IO ()
  , metricsSetDbBlockHeight :: BlockNo -> IO ()
  , metricsSetDbSlotHeight :: SlotNo -> IO ()
  }

data Metrics = Metrics
  { mNodeBlockHeight :: !Gauge
  -- ^ The block tip number of the remote node.
  , mDbQueueLength :: !Gauge
  -- ^ The number of @DbAction@ remaining for the database.
  , mDbBlockHeight :: !Gauge
  -- ^ The block tip number in the database.
  , mDbSlotHeight :: !Gauge
  -- ^ The slot tip number in the database.
  }

-- This enables us to be much more flexibile with what we actually measure.
withMetricSetters :: Int -> (MetricSetters -> IO a) -> IO a
withMetricSetters prometheusPort action =
  withMetricsServer prometheusPort $ \metrics -> do
    action $
      MetricSetters
        { metricsSetNodeBlockHeight = \ (BlockNo nodeHeight) ->
            Gauge.set (fromIntegral nodeHeight) $ mNodeBlockHeight metrics
        , metricsSetDbQueueLength = \ queuePostWrite ->
            Gauge.set (fromIntegral queuePostWrite) $ mDbQueueLength metrics
        , metricsSetDbBlockHeight = \ (BlockNo blockNo) ->
            Gauge.set (fromIntegral blockNo) $ mDbBlockHeight metrics
        , metricsSetDbSlotHeight = \ (SlotNo slotNo) ->
            Gauge.set (fromIntegral slotNo) $ mDbSlotHeight metrics
        }

withMetricsServer :: Int -> (Metrics -> IO a) -> IO a
withMetricsServer port action = do
  -- Using both `RegistryT` and `bracket` here is overkill. Unfortunately the
  -- Prometheus API requires the use of a `Registry` and this seems to be the
  -- least sucky way of doing it.
  (metrics, registry) <- runRegistryT $ (,) <$> makeMetrics <*> RegistryT ask
  bracket
     (async $ runReaderT (unRegistryT $ serveMetricsT port []) registry)
     cancel
     (const $ action metrics)

makeMetrics :: RegistryT IO Metrics
makeMetrics =
  Metrics
    <$> registerGauge "cardano_db_sync_node_block_height" mempty
    <*> registerGauge "cardano_db_sync_db_queue_length" mempty
    <*> registerGauge "cardano_db_sync_db_block_height" mempty
    <*> registerGauge "cardano_db_sync_db_slot_height" mempty
