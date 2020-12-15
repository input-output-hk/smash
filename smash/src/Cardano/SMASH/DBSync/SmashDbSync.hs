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
  , NetworkName (..)
  , SocketPath (..)

  , runDbSyncNode
  ) where

import           Prelude                                               (String)
import qualified Prelude

import           Control.Monad.Trans.Except.Extra                      (firstExceptT,
                                                                        hoistEither,
                                                                        newExceptT)
import           Control.Tracer                                        (Tracer, contramap)

import           Cardano.BM.Data.Tracer                                (ToLogObject (..))
import qualified Cardano.BM.Setup                                      as Logging
import           Cardano.BM.Trace                                      (Trace, appendName,
                                                                        logInfo,
                                                                        modifyName)
import qualified Cardano.BM.Trace                                      as Logging
import qualified Cardano.Crypto                                        as Crypto

import           Cardano.Client.Subscription                           (subscribe)

import           Cardano.SMASH.DB                                      (DataLayer (..))
import qualified Cardano.SMASH.DB                                      as DB
import           Cardano.SMASH.DBSync.Db.Database
import           Cardano.SMASH.DBSync.Metrics

import           Cardano.DbSync.Config
import           Cardano.DbSync.Config.Types                           hiding (adjustGenesisFilePath)
import           Cardano.DbSync.Error
import           Cardano.DbSync.Plugin                                 (DbSyncNodePlugin (..))
import           Cardano.DbSync.Tracing.ToObjectOrphans                ()

import           Cardano.DbSync.Util

import           Cardano.Prelude                                       hiding
                                                                        (Nat,
                                                                        option,
                                                                        (%))

import           Cardano.Slotting.Slot                                 (SlotNo (..),
                                                                        WithOrigin (..),
                                                                        unEpochSize)

import qualified Codec.CBOR.Term                                       as CBOR
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
import           Ouroboros.Network.Protocol.LocalStateQuery.Client     (localStateQueryClientPeer)

import           Ouroboros.Consensus.Block.Abstract                    (ConvertRawHash (..))
import           Ouroboros.Consensus.BlockchainTime.WallClock.Types    (mkSlotLength,
                                                                        slotLengthToMillisec)
import           Ouroboros.Consensus.Byron.Ledger                      (CodecConfig,
                                                                        mkByronCodecConfig)
import           Ouroboros.Consensus.Cardano.Block                     (CardanoEras,
                                                                        CodecConfig (CardanoCodecConfig),
                                                                        StandardCrypto,
                                                                        StandardShelley)
import           Ouroboros.Consensus.Network.NodeToClient              (ClientCodecs,
                                                                        cChainSyncCodec,
                                                                        cStateQueryCodec,
                                                                        cTxSubmissionCodec)
import           Ouroboros.Consensus.Node.ErrorPolicy                  (consensusErrorPolicy)
import           Ouroboros.Consensus.Shelley.Ledger.Config             (CodecConfig (ShelleyCodecConfig))
import           Ouroboros.Consensus.Shelley.Node                      (ShelleyGenesis (..))

import qualified Ouroboros.Network.NodeToClient.Version                as Network

import           Ouroboros.Network.Block                               (BlockNo (..),
                                                                        HeaderHash,
                                                                        Point (..),
                                                                        Tip,
                                                                        blockNo,
                                                                        genesisPoint,
                                                                        getTipBlockNo,
                                                                        getTipPoint)
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


import qualified Shelley.Spec.Ledger.Genesis                           as Shelley

import           System.Directory                                      (createDirectoryIfMissing)
import qualified System.Metrics.Prometheus.Metric.Gauge                as Gauge


import           Ouroboros.Consensus.HardFork.History.Qry              (Interpreter)

import           Cardano.DbSync                                        (MigrationDir (..))
import           Cardano.DbSync.DbAction
import           Cardano.DbSync.LedgerState
import           Cardano.DbSync.StateQuery

import qualified Cardano.Chain.Genesis                                 as Byron


data Peer = Peer SockAddr SockAddr deriving Show


-- | The product type of all command line arguments
data SmashDbSyncNodeParams = SmashDbSyncNodeParams
  { senpConfigFile     :: !ConfigFile
  , senpSocketPath     :: !SocketPath
  , senpLedgerStateDir :: !LedgerStateDir
  , senpMigrationDir   :: !DB.SmashMigrationDir
  , senpMaybeRollback  :: !(Maybe SlotNo)
  }

convertSmashToDbSyncParams :: SmashDbSyncNodeParams -> DbSyncNodeParams
convertSmashToDbSyncParams smashParams =
    DbSyncNodeParams
        { enpConfigFile = senpConfigFile smashParams
        , enpSocketPath = senpSocketPath smashParams
        , enpLedgerStateDir = senpLedgerStateDir smashParams
        , enpMigrationDir = MigrationDir . DB.getSmashMigrationDir $ senpMigrationDir smashParams
        , enpMaybeRollback = senpMaybeRollback smashParams
        }

runDbSyncNode :: DataLayer -> (DataLayer -> DbSyncNodePlugin) -> SmashDbSyncNodeParams -> IO ()
runDbSyncNode dataLayer plugin enp =
  withIOManager $ \iomgr -> do

    let configFile = senpConfigFile enp
    enc <- readDbSyncNodeConfig configFile

    createDirectoryIfMissing True (unLedgerStateDir $ senpLedgerStateDir enp)

    trce <- if not (dncEnableLogging enc)
              then pure Logging.nullTracer
              else liftIO $ Logging.setupTrace (Right $ dncLoggingConfig enc) "smash-node"

    logInfo trce $ "Using byron genesis file from: " <> (show . unGenesisFile $ dncByronGenesisFile enc)
    logInfo trce $ "Using shelley genesis file from: " <> (show . unGenesisFile $ dncShelleyGenesisFile enc)

    logInfo trce $ "Running migrations."

    DB.runMigrations trce Prelude.id (senpMigrationDir enp) (Just $ DB.SmashLogFileDir "/tmp")

    logInfo trce $ "Migrations complete."

    orDie renderDbSyncNodeError $ do
      liftIO . logInfo trce $ "Reading genesis config."

      genCfg <- readCardanoGenesisConfig enc
      genesisEnv <- hoistEither $ genesisConfigToEnv (convertSmashToDbSyncParams enp) genCfg

      logProtocolMagicId trce $ genesisProtocolMagicId genCfg

      liftIO . logInfo trce $ "Starting DB."

      liftIO $ do
        -- Must run plugin startup after the genesis distribution has been inserted/validate.
        logInfo trce $ "Run DB startup."
        runDbStartup trce (plugin dataLayer)
        logInfo trce $ "DB startup complete."
        case genCfg of
          GenesisCardano _ bCfg sCfg -> do
            orDie renderDbSyncNodeError $ insertValidateGenesisDistSmash dataLayer trce (dncNetworkName enc) (scConfig sCfg)

            ledgerVar <- initLedgerStateVar genCfg
            runDbSyncNodeNodeClient dataLayer genesisEnv ledgerVar
                iomgr trce (plugin dataLayer) (cardanoCodecConfig bCfg) (senpSocketPath enp)

  where
    cardanoCodecConfig :: Byron.Config -> CodecConfig CardanoBlock
    cardanoCodecConfig cfg =
      CardanoCodecConfig
        (mkByronCodecConfig cfg)
        ShelleyCodecConfig
        ShelleyCodecConfig -- Allegra
        ShelleyCodecConfig -- Mary

    logProtocolMagicId :: Trace IO Text -> Crypto.ProtocolMagicId -> ExceptT DbSyncNodeError IO ()
    logProtocolMagicId tracer pm =
      liftIO . logInfo tracer $ mconcat
        [ "NetworkMagic: ", textShow (Crypto.unProtocolMagicId pm)
        ]

-- | Idempotent insert the initial Genesis distribution transactions into the DB.
-- If these transactions are already in the DB, they are validated.
insertValidateGenesisDistSmash
    :: DataLayer
    -> Trace IO Text
    -> NetworkName
    -> ShelleyGenesis StandardShelley
    -> ExceptT DbSyncNodeError IO ()
insertValidateGenesisDistSmash dataLayer tracer (NetworkName networkName) cfg = do
    newExceptT $ insertAtomicAction
  where
    insertAtomicAction :: IO (Either DbSyncNodeError ())
    insertAtomicAction = do
      -- TODO(KS): This needs to be moved into DataLayer.
      ebid <- DB.runDbIohkLogging tracer $ DB.queryBlockId (configGenesisHash cfg)
      case ebid of
        -- TODO(KS): This needs to be moved into DataLayer.
        Right _bid -> DB.runDbIohkLogging tracer $ validateGenesisDistribution tracer networkName cfg
        Left _ -> do
            liftIO $ logInfo tracer "Inserting Genesis distribution"
            let meta =  DB.Meta
                            (protocolConstant cfg)
                            (configSlotDuration cfg)
                            (configStartTime cfg)
                            (configSlotsPerEpoch cfg)
                            (Just networkName)

            let block = DB.Block
                            { DB.blockHash = configGenesisHash cfg
                            , DB.blockEpochNo = Nothing
                            , DB.blockSlotNo = Nothing
                            , DB.blockBlockNo = Nothing
                            }

            let addGenesisMetaBlock = dlAddGenesisMetaBlock dataLayer
            metaIdBlockIdE <- addGenesisMetaBlock meta block

            case metaIdBlockIdE of
                Right (_metaId, _blockId) -> pure $ Right ()
                Left err                  -> pure . Left . NEError $ show err

-- | Validate that the initial Genesis distribution in the DB matches the Genesis data.
validateGenesisDistribution
    :: (MonadIO m)
    => Trace IO Text -> Text -> ShelleyGenesis StandardShelley
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

configGenesisHash :: ShelleyGenesis StandardShelley -> ByteString
configGenesisHash _ = BS.take 32 ("GenesisHash " <> BS.replicate 32 '\0')

protocolConstant :: ShelleyGenesis StandardShelley -> Word64
protocolConstant = Shelley.sgSecurityParam

-- | The genesis data is a NominalDiffTime (in picoseconds) and we need
-- it as milliseconds.
configSlotDuration :: ShelleyGenesis StandardShelley -> Word64
configSlotDuration =
  fromIntegral . slotLengthToMillisec . mkSlotLength . sgSlotLength

configSlotsPerEpoch :: ShelleyGenesis StandardShelley -> Word64
configSlotsPerEpoch sg = unEpochSize (Shelley.sgEpochLength sg)

configStartTime :: ShelleyGenesis StandardShelley -> UTCTime
configStartTime = roundToMillseconds . Shelley.sgSystemStart

roundToMillseconds :: UTCTime -> UTCTime
roundToMillseconds (UTCTime day picoSecs) =
    UTCTime day (Time.picosecondsToDiffTime $ 1000000 * (picoSeconds `div` 1000000))
  where
    picoSeconds :: Integer
    picoSeconds = Time.diffTimeToPicoseconds picoSecs

---------------------------------------------------------------------------------------------------

runDbSyncNodeNodeClient
    :: DataLayer
    -> DbSyncEnv
    -> LedgerStateVar
    -> IOManager
    -> Trace IO Text
    -> DbSyncNodePlugin
    -> CodecConfig CardanoBlock
    -> SocketPath
    -> IO ()
runDbSyncNodeNodeClient dataLayer env ledgerVar iomgr trce plugin codecConfig (SocketPath socketPath) = do
  queryVar <- newStateQueryTMVar
  logInfo trce $ "localInitiatorNetworkApplication: connecting to node via " <> textShow socketPath

  void $ subscribe
    (localSnocket iomgr socketPath)
    codecConfig
    (envNetworkMagic env)
    networkSubscriptionTracers
    clientSubscriptionParams
    (dbSyncProtocols dataLayer trce env plugin queryVar ledgerVar)
  where
    clientSubscriptionParams = ClientSubscriptionParams {
        cspAddress = Snocket.localAddressFromPath socketPath,
        cspConnectionAttemptDelay = Nothing,
        cspErrorPolicies = networkErrorPolicies <> consensusErrorPolicy (Proxy @CardanoBlock)
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

-- Db sync protocols.
dbSyncProtocols
    :: DataLayer
    -> Trace IO Text
    -> DbSyncEnv
    -> DbSyncNodePlugin
    -> StateQueryTMVar CardanoBlock (Interpreter (CardanoEras StandardCrypto))
    -> LedgerStateVar
    -> Network.NodeToClientVersion
    -> ClientCodecs CardanoBlock IO
    -> ConnectionId LocalAddress
    -> NodeToClientProtocols 'InitiatorMode BSL.ByteString IO () Void
dbSyncProtocols dataLayer trce env plugin queryVar ledgerVar _version codecs _connectionId =
    NodeToClientProtocols {
          localChainSyncProtocol = localChainSyncProtocol
        , localTxSubmissionProtocol = dummylocalTxSubmit
        , localStateQueryProtocol = localStateQuery
        }
  where
    localChainSyncTracer :: Tracer IO (TraceSendRecv (ChainSync CardanoBlock(Point CardanoBlock) (Tip CardanoBlock)))
    localChainSyncTracer = toLogObject $ appendName "ChainSync" trce

    localChainSyncProtocol :: RunMiniProtocol 'InitiatorMode BSL.ByteString IO () Void
    localChainSyncProtocol = InitiatorProtocolOnly $ MuxPeerRaw $ \channel ->
      liftIO . logException trce "ChainSyncWithBlocksPtcl: " $ do
        logInfo trce "Starting localChainSyncProtocol."

        latestPoints <- getLatestPoints dataLayer (envLedgerStateDir env)
        currentTip <- getCurrentTipBlockNo trce
        logDbState trce
        actionQueue <- newDbActionQueue
        (metrics, server) <- registerMetricsServer 8080

        logInfo trce "Starting threads for client, db and offline fetch thread."

        race_
            (race_
                (runDbThread trce env plugin metrics actionQueue ledgerVar)
                (runOfflineFetchThread $ modifyName (const "fetch") trce)
            )
            (runPipelinedPeer
                localChainSyncTracer
                (cChainSyncCodec codecs)
                channel
                (chainSyncClientPeerPipelined
                    $ chainSyncClient trce env queryVar metrics latestPoints currentTip actionQueue)
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

    localStateQuery :: RunMiniProtocol 'InitiatorMode BSL.ByteString IO () Void
    localStateQuery =
      InitiatorProtocolOnly $ MuxPeer
        (contramap (Text.pack . show) . toLogObject $ appendName "local-state-query" trce)
        (cStateQueryCodec codecs)
        (localStateQueryClientPeer (localStateQueryHandler queryVar))

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


getLatestPoints :: DataLayer -> LedgerStateDir -> IO [Point CardanoBlock]
getLatestPoints dataLayer ledgerStateDir = do
    xs <- listLedgerStateSlotNos ledgerStateDir

    let getSlotHash = dlGetSlotHash dataLayer
    ys <- catMaybes <$> mapM getSlotHash xs

    pure $ mapMaybe convert ys
  where
    convert :: (SlotNo, ByteString) -> Maybe (Point CardanoBlock)
    convert (slot, hashBlob) =
      fmap (Point . Point.block slot) (convertHashBlob hashBlob)

    convertHashBlob :: ByteString -> Maybe (HeaderHash CardanoBlock)
    convertHashBlob = Just . fromRawHash (Proxy @CardanoBlock)

getCurrentTipBlockNo :: Trace IO Text -> IO (WithOrigin BlockNo)
getCurrentTipBlockNo trce = do
    maybeTip <- DB.runDbNoLogging DB.queryLatestBlock
    case maybeTip of
      Just tip -> pure $ convert tip
      Nothing -> do
          logInfo trce "Current tip block, Nothing."
          pure Origin
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
chainSyncClient
    :: Trace IO Text -> DbSyncEnv
    -> StateQueryTMVar CardanoBlock (Interpreter (CardanoEras StandardCrypto))
    -> Metrics -> [Point CardanoBlock] -> WithOrigin BlockNo -> DbActionQueue
    -> ChainSyncClientPipelined CardanoBlock (Point CardanoBlock) (Tip CardanoBlock) IO ()
chainSyncClient trce env queryVar metrics latestPoints currentTip actionQueue = do
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
        -> ClientPipelinedStIdle n CardanoBlock (Point CardanoBlock) (Tip CardanoBlock) IO ()
    go mkPipelineDecision n clientTip serverTip =
      case (n, runPipelineDecision mkPipelineDecision n clientTip serverTip) of
        (_Zero, (Request, mkPipelineDecision')) -> do
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

    mkClientStNext :: (WithOrigin BlockNo -> Tip CardanoBlock
                    -> ClientPipelinedStIdle n CardanoBlock (Point CardanoBlock) (Tip CardanoBlock) IO a)
                    -> ClientStNext n CardanoBlock (Point CardanoBlock) (Tip CardanoBlock) IO a
    mkClientStNext finish =
      ClientStNext
        { recvMsgRollForward = \blk tip -> do
              logException trce "recvMsgRollForward: " $ do
                Gauge.set (withOrigin 0 (fromIntegral . unBlockNo) (getTipBlockNo tip)) (mNodeHeight metrics)
                details <- getSlotDetails trce env queryVar (getTipPoint tip) (cardanoBlockSlotNo blk)
                newSize <- atomically $ do
                            writeDbActionQueue actionQueue $ mkDbApply blk details
                            lengthDbActionQueue actionQueue
                Gauge.set (fromIntegral newSize) $ mQueuePostWrite metrics
                pure $ finish (At (blockNo blk)) tip
        , recvMsgRollBackward = \point tip -> do
              logException trce "recvMsgRollBackward: " $ do
                -- This will get the current tip rather than what we roll back to
                -- but will only be incorrect for a short time span.
                let slot = toRollbackSlot point
                atomically $ writeDbActionQueue actionQueue (mkDbRollback slot)
                newTip <- getCurrentTipBlockNo trce
                pure $ finish newTip tip
        }
