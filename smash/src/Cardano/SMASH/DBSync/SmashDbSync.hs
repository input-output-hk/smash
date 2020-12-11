{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}

module Cardano.SMASH.DBSync.SmashDbSync
  ( ConfigFile (..)
  , SmashDbSyncNodeParams (..)
  , DbSyncNodePlugin (..)
  , GenesisHash (..)
  , NetworkName (..)
  , SocketPath (..)

  , runDbSyncNode
  ) where

import           Prelude                                               (String)
import qualified Prelude

import           Control.Monad.Trans.Except.Extra                      (firstExceptT,
                                                                        hoistEither,
                                                                        newExceptT)
import           Control.Tracer                                        (Tracer)

import           Cardano.BM.Data.Tracer                                (ToLogObject (..))
import qualified Cardano.BM.Setup                                      as Logging
import           Cardano.BM.Trace                                      (Trace, appendName,
                                                                        logInfo,
                                                                        modifyName)
import qualified Cardano.BM.Trace                                      as Logging

import           Cardano.Client.Subscription                           (subscribe)

import qualified Cardano.SMASH.DB                                      as DB

import           Cardano.SMASH.DBSync.Db.Database
import           Cardano.SMASH.DBSync.Metrics

import           Cardano.DbSync.Config
import           Cardano.DbSync.Era
import           Cardano.DbSync.Error
import           Cardano.DbSync.Plugin                                 (DbSyncNodePlugin (..))
import           Cardano.DbSync.Tracing.ToObjectOrphans                ()
import           Cardano.DbSync.Types                                  (ConfigFile (..),
                                                                        DbSyncEnv (..),
                                                                        EpochSlot (..),
                                                                        SlotDetails (..),
                                                                        SocketPath (..))
import           Cardano.DbSync.Util

import           Cardano.Prelude                                       hiding
                                                                        (Nat,
                                                                        option,
                                                                        (%))

import           Cardano.Slotting.Slot                                 (SlotNo (..),
                                                                        WithOrigin (..),
                                                                        unEpochSize)

import qualified Codec.CBOR.Term                                       as CBOR
import           Control.Monad.Class.MonadTimer                        (MonadTimer)
import           Control.Monad.IO.Class                                (liftIO)
import           Control.Monad.Trans.Except.Exit                       (orDie)

import qualified Data.ByteString.Char8                                 as BS
import qualified Data.ByteString.Lazy                                  as BSL
import           Data.Text                                             (Text)
import qualified Data.Text                                             as Text
import           Data.Time                                             (UTCTime (..))
import qualified Data.Time                                             as Time
import           Data.Void                                             (Void)

import           Database.Persist.Sql                                  (SqlBackend)

import           Network.Mux                                           (MuxTrace,
                                                                        WithMuxBearer)
import           Network.Mux.Types                                     (MuxMode (..))
import           Network.Socket                                        (SockAddr (..))

import           Network.TypedProtocol.Pipelined                       (Nat (Succ, Zero))

import           Cardano.SMASH.Offline                                 (runOfflineFetchThread)

import           Ouroboros.Network.Driver.Simple                       (runPipelinedPeer)

import           Ouroboros.Consensus.Block.Abstract                    (ConvertRawHash (..))
import           Ouroboros.Consensus.BlockchainTime.WallClock.Types    (mkSlotLength,
                                                                        slotLengthToMillisec)
import           Ouroboros.Consensus.Byron.Ledger                      (CodecConfig,
                                                                        mkByronCodecConfig)
import           Ouroboros.Consensus.Network.NodeToClient              (ClientCodecs,
                                                                        cChainSyncCodec,
                                                                        cStateQueryCodec,
                                                                        cTxSubmissionCodec)
import           Ouroboros.Consensus.Node.ErrorPolicy                  (consensusErrorPolicy)
import           Ouroboros.Consensus.Node.Run                          (RunNode)
import           Ouroboros.Consensus.Shelley.Ledger.Config             (CodecConfig (ShelleyCodecConfig))

import qualified Ouroboros.Network.NodeToClient.Version                as Network

import           Ouroboros.Network.Block                               (BlockNo (..),
                                                                        HeaderHash,
                                                                        Point (..),
                                                                        Tip,
                                                                        blockNo,
                                                                        genesisPoint,
                                                                        getTipBlockNo)
import           Ouroboros.Network.Mux                                 (MuxPeer (..),
                                                                        RunMiniProtocol (..))
import           Ouroboros.Network.NodeToClient                        (ClientSubscriptionParams (..),
                                                                        ConnectionId,
                                                                        ErrorPolicyTrace (..),
                                                                        Handshake,
                                                                        IOManager,
                                                                        LocalAddress,
                                                                        NetworkSubscriptionTracers (..),
                                                                        NodeToClientProtocols (..),
                                                                        TraceSendRecv,
                                                                        WithAddr (..),
                                                                        localSnocket,
                                                                        localStateQueryPeerNull,
                                                                        localTxSubmissionPeerNull,
                                                                        networkErrorPolicies,
                                                                        withIOManager)

import           Ouroboros.Network.Point                               (withOrigin)
import qualified Ouroboros.Network.Point                               as Point

import           Ouroboros.Network.Protocol.ChainSync.ClientPipelined  (ChainSyncClientPipelined (..),
                                                                        ClientPipelinedStIdle (..),
                                                                        ClientPipelinedStIntersect (..),
                                                                        ClientStNext (..),
                                                                        chainSyncClientPeerPipelined,
                                                                        recvMsgIntersectFound,
                                                                        recvMsgIntersectNotFound,
                                                                        recvMsgRollBackward,
                                                                        recvMsgRollForward)
import           Ouroboros.Network.Protocol.ChainSync.PipelineDecision (MkPipelineDecision,
                                                                        PipelineDecision (..),
                                                                        pipelineDecisionLowHighMark,
                                                                        runPipelineDecision)
import           Ouroboros.Network.Protocol.ChainSync.Type             (ChainSync)
import qualified Ouroboros.Network.Snocket                             as Snocket
import           Ouroboros.Network.Subscription                        (SubscriptionTrace)

import           Ouroboros.Consensus.Cardano.Block
import           Ouroboros.Consensus.Shelley.Node                      (ShelleyGenesis (..))
import           Ouroboros.Consensus.Shelley.Protocol                  (TPraosStandardCrypto)

import qualified Shelley.Spec.Ledger.Genesis                           as Shelley
import           System.FilePath

import qualified System.Metrics.Prometheus.Metric.Gauge                as Gauge

import qualified Cardano.SMASH.DBSync.Db.Insert                        as DB


data Peer = Peer SockAddr SockAddr deriving Show


-- | The product type of all command line arguments
data SmashDbSyncNodeParams = SmashDbSyncNodeParams
  { senpConfigFile    :: !ConfigFile
  , senpSocketPath    :: !SocketPath
  , senpMigrationDir  :: !DB.SmashMigrationDir
  , senpMaybeRollback :: !(Maybe SlotNo)
  }

adjustGenesisFilePath :: (FilePath -> FilePath) -> GenesisFile -> GenesisFile
adjustGenesisFilePath f (GenesisFile p) = GenesisFile (f p)

mkAdjustPath :: ConfigFile -> (FilePath -> FilePath)
mkAdjustPath (ConfigFile configFile) fp = takeDirectory configFile </> fp

runDbSyncNode :: DbSyncNodePlugin -> SmashDbSyncNodeParams -> IO ()
runDbSyncNode plugin enp =
  withIOManager $ \iomgr -> do

    let configFile = senpConfigFile enp
    readEnc <- readDbSyncNodeConfig (unConfigFile configFile)

    -- Fix genesis paths to be relative to the config file directory.
    -- Absolute paths are valid!
    let enc = readEnc
            { encByronGenesisFile = adjustGenesisFilePath (mkAdjustPath configFile) (encByronGenesisFile readEnc)
            , encShelleyGenesisFile = adjustGenesisFilePath (mkAdjustPath configFile) (encShelleyGenesisFile readEnc)
            }

    trce <- if not (encEnableLogging enc)
              then pure Logging.nullTracer
              else liftIO $ Logging.setupTrace (Right $ encLoggingConfig enc) "smash-node"

    logInfo trce $ "Using byron genesis file from: " <> (show . unGenesisFile $ encByronGenesisFile enc)
    logInfo trce $ "Using shelley genesis file from: " <> (show . unGenesisFile $ encShelleyGenesisFile enc)

    logInfo trce $ "Running migrations."

    DB.runMigrations trce Prelude.id (senpMigrationDir enp) (Just $ DB.SmashLogFileDir "/tmp")

    logInfo trce $ "Migrations complete."

    orDie renderDbSyncNodeError $ do
      liftIO . logInfo trce $ "Reading genesis config."

      genCfg <- readGenesisConfig enc
      genesisEnv <- hoistEither $ genesisConfigToEnv genCfg

      liftIO . logInfo trce $ "Starting DB."

      liftIO $ do
        -- Must run plugin startup after the genesis distribution has been inserted/validate.
        logInfo trce $ "Run DB startup."
        runDbStartup trce plugin
        logInfo trce $ "DB startup complete."
        case genCfg of
          GenesisCardano bCfg sCfg -> do
            orDie renderDbSyncNodeError $ insertValidateGenesisDistSmash trce (encNetworkName enc) sCfg
            runDbSyncNodeNodeClient genesisEnv
                iomgr trce plugin cardanoCodecConfig (senpSocketPath enp)
            where
              cardanoCodecConfig :: CardanoCodecConfig TPraosStandardCrypto
              cardanoCodecConfig =
                CardanoCodecConfig (mkByronCodecConfig bCfg)
                                   ShelleyCodecConfig

-- | Idempotent insert the initial Genesis distribution transactions into the DB.
-- If these transactions are already in the DB, they are validated.
insertValidateGenesisDistSmash
    :: Trace IO Text -> NetworkName -> ShelleyGenesis TPraosStandardCrypto
    -> ExceptT DbSyncNodeError IO ()
insertValidateGenesisDistSmash tracer (NetworkName networkName) cfg =
    newExceptT $ DB.runDbIohkLogging tracer insertAction
  where
    insertAction :: (MonadIO m) => ReaderT SqlBackend m (Either DbSyncNodeError ())
    insertAction = do
      ebid <- DB.queryBlockId (configGenesisHash cfg)
      case ebid of
        Right _bid -> validateGenesisDistribution tracer networkName cfg
        Left _ ->
          runExceptT $ do
            liftIO $ logInfo tracer "Inserting Genesis distribution"
            count <- lift DB.queryBlockCount

            when (count > 0) $
              dbSyncNodeError "Shelley.insertValidateGenesisDist: Genesis data mismatch."
            void . lift . DB.insertMeta
                $ DB.Meta
                    (protocolConstant cfg)
                    (configSlotDuration cfg)
                    (configStartTime cfg)
                    (configSlotsPerEpoch cfg)
                    (Just networkName)
            -- Insert an 'artificial' Genesis block (with a genesis specific slot leader). We
            -- need this block to attach the genesis distribution transactions to.
            _blockId <- lift . DB.insertBlock $
                      DB.Block
                        { DB.blockHash = configGenesisHash cfg
                        , DB.blockEpochNo = Nothing
                        , DB.blockSlotNo = Nothing
                        , DB.blockBlockNo = Nothing
                        }

            pure ()

-- | Validate that the initial Genesis distribution in the DB matches the Genesis data.
validateGenesisDistribution
    :: (MonadIO m)
    => Trace IO Text -> Text -> ShelleyGenesis TPraosStandardCrypto
    -> ReaderT SqlBackend m (Either DbSyncNodeError ())
validateGenesisDistribution tracer networkName cfg =
  runExceptT $ do
    liftIO $ logInfo tracer "Validating Genesis distribution"
    meta <- firstExceptT (\(e :: DB.DBFail) -> NEError $ show e) . newExceptT $ DB.queryMeta

    -- Show configuration we are validating
    print cfg

    when (DB.metaProtocolConst meta /= protocolConstant cfg) $
      dbSyncNodeError $ Text.concat
            [ "Shelley: Mismatch protocol constant. Config value "
            , textShow (protocolConstant cfg)
            , " does not match DB value of ", textShow (DB.metaProtocolConst meta)
            ]

    when (DB.metaSlotDuration meta /= configSlotDuration cfg) $
      dbSyncNodeError $ Text.concat
            [ "Shelley: Mismatch slot duration time. Config value "
            , textShow (configSlotDuration cfg)
            , " does not match DB value of ", textShow (DB.metaSlotDuration meta)
            ]

    when (DB.metaStartTime meta /= configStartTime cfg) $
      dbSyncNodeError $ Text.concat
            [ "Shelley: Mismatch chain start time. Config value "
            , textShow (configStartTime cfg)
            , " does not match DB value of ", textShow (DB.metaStartTime meta)
            ]

    when (DB.metaSlotsPerEpoch meta /= configSlotsPerEpoch cfg) $
      dbSyncNodeError $ Text.concat
            [ "Shelley: Mismatch in slots per epoch. Config value "
            , textShow (configSlotsPerEpoch cfg)
            , " does not match DB value of ", textShow (DB.metaSlotsPerEpoch meta)
            ]

    case DB.metaNetworkName meta of
      Nothing ->
        dbSyncNodeError $ "Shelley.validateGenesisDistribution: Missing network name"
      Just name ->
        when (name /= networkName) $
          dbSyncNodeError $ Text.concat
              [ "Shelley.validateGenesisDistribution: Provided network name "
              , networkName
              , " does not match DB value "
              , name
              ]

---------------------------------------------------------------------------------------------------


configGenesisHash :: ShelleyGenesis TPraosStandardCrypto -> ByteString
configGenesisHash _ = fakeGenesisHash
  where
    -- | This is both the Genesis Hash and the hash of the previous block.
    fakeGenesisHash :: ByteString
    fakeGenesisHash = BS.take 32 ("GenesisHash " <> BS.replicate 32 '\0')

protocolConstant :: ShelleyGenesis TPraosStandardCrypto -> Word64
protocolConstant = Shelley.sgSecurityParam

-- | The genesis data is a NominalDiffTime (in picoseconds) and we need
-- it as milliseconds.
configSlotDuration :: ShelleyGenesis TPraosStandardCrypto -> Word64
configSlotDuration =
  fromIntegral . slotLengthToMillisec . mkSlotLength . sgSlotLength

configSlotsPerEpoch :: ShelleyGenesis TPraosStandardCrypto -> Word64
configSlotsPerEpoch sg = unEpochSize (Shelley.sgEpochLength sg)

configStartTime :: ShelleyGenesis TPraosStandardCrypto -> UTCTime
configStartTime = roundToMillseconds . Shelley.sgSystemStart

roundToMillseconds :: UTCTime -> UTCTime
roundToMillseconds (UTCTime day picoSecs) =
    UTCTime day (Time.picosecondsToDiffTime $ 1000000 * (picoSeconds `div` 1000000))
  where
    picoSeconds :: Integer
    picoSeconds = Time.diffTimeToPicoseconds picoSecs

---------------------------------------------------------------------------------------------------

runDbSyncNodeNodeClient
    :: forall blk. (MkDbAction blk, RunNode blk)
    => DbSyncEnv -> IOManager -> Trace IO Text -> DbSyncNodePlugin -> CodecConfig blk-> SocketPath
    -> IO ()
runDbSyncNodeNodeClient env iomgr trce plugin codecConfig (SocketPath socketPath) = do
  logInfo trce $ "localInitiatorNetworkApplication: connecting to node via " <> textShow socketPath

  void $ subscribe
    (localSnocket iomgr socketPath)
    codecConfig
    (envNetworkMagic env)
    networkSubscriptionTracers
    clientSubscriptionParams
    (dbSyncProtocols trce env plugin)
  where
    clientSubscriptionParams = ClientSubscriptionParams {
        cspAddress = Snocket.localAddressFromPath socketPath,
        cspConnectionAttemptDelay = Nothing,
        cspErrorPolicies = networkErrorPolicies <> consensusErrorPolicy
        }

    networkSubscriptionTracers = NetworkSubscriptionTracers {
        nsMuxTracer = muxTracer,
        nsHandshakeTracer = handshakeTracer,
        nsErrorPolicyTracer = errorPolicyTracer,
        nsSubscriptionTracer = subscriptionTracer
        }

    errorPolicyTracer :: Tracer IO (WithAddr LocalAddress ErrorPolicyTrace)
    errorPolicyTracer = toLogObject $ appendName "ErrorPolicy" trce

    muxTracer :: Show peer => Tracer IO (WithMuxBearer peer MuxTrace)
    muxTracer = toLogObject $ appendName "Mux" trce

    subscriptionTracer :: Tracer IO (Identity (SubscriptionTrace LocalAddress))
    subscriptionTracer = toLogObject $ appendName "Subscription" trce

    handshakeTracer :: Tracer IO (WithMuxBearer
                          (ConnectionId LocalAddress)
                          (TraceSendRecv (Handshake Network.NodeToClientVersion CBOR.Term)))
    handshakeTracer = toLogObject $ appendName "Handshake" trce

dbSyncProtocols
  :: forall blk. (MkDbAction blk, RunNode blk)
  => Trace IO Text
  -> DbSyncEnv
  -> DbSyncNodePlugin
  -> Network.NodeToClientVersion
  -> ClientCodecs blk IO
  -> ConnectionId LocalAddress
  -> NodeToClientProtocols 'InitiatorMode BSL.ByteString IO () Void
dbSyncProtocols trce env plugin _version codecs _connectionId =
    NodeToClientProtocols {
          localChainSyncProtocol = localChainSyncProtocol
        , localTxSubmissionProtocol = dummylocalTxSubmit
        , localStateQueryProtocol = dummyLocalQueryProtocol
        }
  where
    localChainSyncTracer :: Tracer IO (TraceSendRecv (ChainSync blk (Tip blk)))
    localChainSyncTracer = toLogObject $ appendName "ChainSync" trce

    localChainSyncProtocol :: RunMiniProtocol 'InitiatorMode BSL.ByteString IO () Void
    localChainSyncProtocol = InitiatorProtocolOnly $ MuxPeerRaw $ \channel ->
      liftIO . logException trce "ChainSyncWithBlocksPtcl: " $ do
        logInfo trce "Starting chainSyncClient"
        latestPoints <- getLatestPoints
        currentTip <- getCurrentTipBlockNo
        logDbState trce
        actionQueue <- newDbActionQueue
        (metrics, server) <- registerMetricsServer 8080
        race_
            (race_
                -- TODO(KS): Watch out! We pass the data layer here directly!
                (runDbThread trce env plugin metrics actionQueue)
                (runOfflineFetchThread $ modifyName (const "fetch") trce)
            )
            (runPipelinedPeer
                localChainSyncTracer
                (cChainSyncCodec codecs)
                channel
                (chainSyncClientPeerPipelined
                    $ chainSyncClient trce metrics latestPoints currentTip actionQueue)
            )
        atomically $ writeDbActionQueue actionQueue DbFinish
        cancel server
        -- We should return leftover bytes returned by 'runPipelinedPeer', but
        -- client application do not care about them (it's only important if one
        -- would like to restart a protocol on the same mux and thus bearer).
        pure ((), Nothing)

    dummylocalTxSubmit :: RunMiniProtocol 'InitiatorMode BSL.ByteString IO () Void
    dummylocalTxSubmit = InitiatorProtocolOnly $ MuxPeer
        Logging.nullTracer
        (cTxSubmissionCodec codecs)
        localTxSubmissionPeerNull

    dummyLocalQueryProtocol :: RunMiniProtocol 'InitiatorMode BSL.ByteString IO () Void
    dummyLocalQueryProtocol =
      InitiatorProtocolOnly $ MuxPeer
        Logging.nullTracer
        (cStateQueryCodec codecs)
        localStateQueryPeerNull

logDbState :: Trace IO Text -> IO ()
logDbState trce = do
    mblk <- DB.runDbNoLogging DB.queryLatestBlock
    case mblk of
      Nothing -> logInfo trce "Cardano.Db is empty"
      Just block ->
          logInfo trce $ Text.concat
                  [ "Cardano.Db tip is at "
                  , Text.pack (showTip block)
                  ]
  where
    showTip :: DB.Block -> String
    showTip blk =
      case (DB.blockSlotNo blk, DB.blockBlockNo blk) of
        (Just slotNo, Just blkNo) -> "slot " ++ show slotNo ++ ", block " ++ show blkNo
        (Just slotNo, Nothing) -> "slot " ++ show slotNo
        (Nothing, Just blkNo) -> "block " ++ show blkNo
        (Nothing, Nothing) -> "empty (genesis)"


getLatestPoints :: forall blk. ConvertRawHash blk => IO [Point blk]
getLatestPoints =
    -- Blocks (and the transactions they contain) are inserted within an SQL transaction.
    -- That means that all the blocks (including their transactions) returned by the query
    -- have been completely inserted.
    mapMaybe convert <$> DB.runDbNoLogging (DB.queryCheckPoints 200)
  where
    convert :: (Word64, ByteString) -> Maybe (Point blk)
    convert (slot, hashBlob) =
      fmap (Point . Point.block (SlotNo slot)) (convertHashBlob hashBlob)

    -- in Maybe because the bytestring may not be the right size.
    convertHashBlob :: ByteString -> Maybe (HeaderHash blk)
    convertHashBlob = Just . fromRawHash (Proxy @blk)

getCurrentTipBlockNo :: IO (WithOrigin BlockNo)
getCurrentTipBlockNo = do
    maybeTip <- DB.runDbNoLogging DB.queryLatestBlock
    case maybeTip of
      Just tip -> pure $ convert tip
      Nothing  -> pure Origin
  where
    convert :: DB.Block -> WithOrigin BlockNo
    convert blk =
      case DB.blockBlockNo blk of
        Just blockno -> At (BlockNo blockno)
        Nothing      -> Origin

-- | 'ChainSyncClient' which traces received blocks and ignores when it
-- receives a request to rollbackwar.  A real wallet client should:
--
--  * at startup send the list of points of the chain to help synchronise with
--    the node;
--  * update its state when the client receives next block or is requested to
--    rollback, see 'clientStNext' below.
--
chainSyncClient
  :: forall blk m. (MonadTimer m, MonadIO m, RunNode blk, MkDbAction blk)
  => Trace IO Text -> Metrics -> [Point blk] -> WithOrigin BlockNo -> DbActionQueue -> ChainSyncClientPipelined blk (Tip blk) m ()
chainSyncClient trce metrics latestPoints currentTip actionQueue =
    ChainSyncClientPipelined $ pure $
      -- Notify the core node about the our latest points at which we are
      -- synchronised.  This client is not persistent and thus it just
      -- synchronises from the genesis block.  A real implementation should send
      -- a list of points up to a point which is k blocks deep.
      SendMsgFindIntersect
        (if null latestPoints then [genesisPoint] else latestPoints)
        ClientPipelinedStIntersect
          { recvMsgIntersectFound    = \_hdr tip -> pure $ go policy Zero currentTip (getTipBlockNo tip)
          , recvMsgIntersectNotFound = \  tip -> pure $ go policy Zero currentTip (getTipBlockNo tip)
          }
  where
    policy = pipelineDecisionLowHighMark 1000 10000

    go :: MkPipelineDecision -> Nat n -> WithOrigin BlockNo -> WithOrigin BlockNo
        -> ClientPipelinedStIdle n blk (Tip blk) m ()
    go mkPipelineDecision n clientTip serverTip =
      case (n, runPipelineDecision mkPipelineDecision n clientTip serverTip) of
        (_Zero, (Request, mkPipelineDecision')) ->
            SendMsgRequestNext clientStNext (pure clientStNext)
          where
            clientStNext = mkClientStNext $ \clientBlockNo newServerTip -> go mkPipelineDecision' n clientBlockNo (getTipBlockNo newServerTip)
        (_, (Pipeline, mkPipelineDecision')) ->
          SendMsgRequestNextPipelined
            (go mkPipelineDecision' (Succ n) clientTip serverTip)
        (Succ n', (CollectOrPipeline, mkPipelineDecision')) ->
          CollectResponse
            (Just $ SendMsgRequestNextPipelined $ go mkPipelineDecision' (Succ n) clientTip serverTip)
            (mkClientStNext $ \clientBlockNo newServerTip -> go mkPipelineDecision' n' clientBlockNo (getTipBlockNo newServerTip))
        (Succ n', (Collect, mkPipelineDecision')) ->
          CollectResponse
            Nothing
            (mkClientStNext $ \clientBlockNo newServerTip -> go mkPipelineDecision' n' clientBlockNo (getTipBlockNo newServerTip))

    mkClientStNext :: (WithOrigin BlockNo -> Tip blk -> ClientPipelinedStIdle n blk (Tip blk) m a)
                    -> ClientStNext n blk (Tip blk) m a
    mkClientStNext finish =
      ClientStNext
        { recvMsgRollForward = \blk tip ->
            liftIO .
              logException trce "recvMsgRollForward: " $ do
                Gauge.set (withOrigin 0 (fromIntegral . unBlockNo) (getTipBlockNo tip))
                          (mNodeHeight metrics)
                let dummySlotDetails =
                      SlotDetails {
                        sdTime      = UTCTime (Time.fromGregorian 1970 1 1) 0
                      , sdEpochNo   = 0
                      , sdEpochSlot = EpochSlot 0
                      , sdEpochSize = 0
                      }
                newSize <- atomically $ do
                  writeDbActionQueue actionQueue $ mkDbApply blk dummySlotDetails
                  lengthDbActionQueue actionQueue
                Gauge.set (fromIntegral newSize) $ mQueuePostWrite metrics
                pure $ finish (At (blockNo blk)) tip
        , recvMsgRollBackward = \point tip ->
            liftIO .
              logException trce "recvMsgRollBackward: " $ do
                -- This will get the current tip rather than what we roll back to
                -- but will only be incorrect for a short time span.
                atomically $ writeDbActionQueue actionQueue $ mkDbRollback point
                newTip <- getCurrentTipBlockNo
                pure $ finish newTip tip
        }
