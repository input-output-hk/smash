{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -freduction-depth=0 #-}

module Cardano.SMASH.ScanBlocksPipelined where

import           Cardano.Prelude hiding (Nat)

import           Cardano.Api
import           Cardano.Api.ChainSync.ClientPipelined
import qualified Cardano.Chain.Slotting as Byron (EpochSlots (..))
import           Cardano.Slotting.Slot

import qualified Cardano.SMASH.DB as DB

import           Data.Time
import           System.FilePath ((</>))

runLocally :: IO ()
runLocally = do
    -- Get cocket path from CLI argument.
    socketDir : _ <- getArgs
    let socketPath = socketDir </> "node.sock"

    -- Connect to the node.
    putStrLn $ "Connecting to socket: " <> socketPath

    pipelinedChainSync socketPath


pipelinedChainSync :: FilePath -> IO ()
pipelinedChainSync socketPath = do
  connectToLocalNode
    (connectInfo socketPath)
    protocols
  where
  connectInfo :: FilePath -> LocalNodeConnectInfo CardanoMode
  connectInfo socketPath =
      LocalNodeConnectInfo {
        localConsensusModeParams = CardanoModeParams (Byron.EpochSlots 21600), -- ConsensusModeParams mode
        localNodeNetworkId       = Mainnet, -- NetworkId
        localNodeSocketPath      = socketPath
      }

  protocols :: LocalNodeClientProtocolsInMode CardanoMode
  protocols =
      LocalNodeClientProtocols {
        localChainSyncClient    = LocalChainSyncClientPipelined (chainSyncClient 50 21600),
        localTxSubmissionClient = Nothing,
        localStateQueryClient   = Nothing
      }


-- | Defines the pipelined client side of the chain sync protocol.
chainSyncClient
  :: Word32
  -- ^ The maximum number of concurrent requests.
  -> Word64
  -> ChainSyncClientPipelined
        (BlockInMode CardanoMode)
        ChainPoint
        ChainTip
        IO
        ()
chainSyncClient pipelineSize slotsPerEpoch = ChainSyncClientPipelined $ do
  startTime <- getCurrentTime
  let
    clientIdleRequestMoreN
        :: WithOrigin BlockNo
        -> WithOrigin BlockNo
        -> Nat n
        -> ClientPipelinedStIdle n (BlockInMode CardanoMode) ChainPoint ChainTip IO ()
    clientIdleRequestMoreN clientTip serverTip n = case pipelineDecisionMax pipelineSize n clientTip serverTip  of
      Collect -> case n of
        Succ predN -> CollectResponse Nothing (clientNextN predN)
      _ -> SendMsgRequestNextPipelined (clientIdleRequestMoreN clientTip serverTip (Succ n))

    clientNextN
        :: Nat n
        -> ClientStNext n (BlockInMode CardanoMode) ChainPoint ChainTip IO ()
    clientNextN n =
      ClientStNext {
          recvMsgRollForward = \(BlockInMode block@(Block (BlockHeader (SlotNo slotNo) blockHeaderHash currBlockNo@(BlockNo blockNo)) _) _) serverChainTip -> do

            -- getBlockHeaderAndTxs :: Block era -> (BlockHeader, [Tx era])
            --let (_blockHeader, blkTxs) = getBlockHeaderAndTxs block

            --let ((SlotNo slotNo) blockHeaderHash currBlockNo@(BlockNo blockNo)) = blockHeader

            let newClientTip = At currBlockNo
                newServerTip = fromChainTip serverChainTip

            -- newClientTip
            let blockHash = serialiseToRawBytes blockHeaderHash
            let epochNo = slotNo `div` slotsPerEpoch

            -- Construct a DB block.
            let _dbBlock :: DB.Block = DB.Block blockHash (Just epochNo) (Just slotNo) (Just blockNo)

            when (blockNo `mod` 1000 == 0) $ do
              printBlock block
              now <- getCurrentTime
              let elapsedTime = realToFrac (now `diffUTCTime` startTime) :: Double
                  rate = fromIntegral blockNo / elapsedTime
              putStrLn $ "Rate = " ++ show rate ++ " blocks/second"

            if newClientTip == newServerTip
              then clientIdleDoneN n
              else return (clientIdleRequestMoreN newClientTip newServerTip n)

        -- We actually don't roll back on SMASH.
        , recvMsgRollBackward = \_ serverChainTip -> do
            let newClientTip = Origin -- We don't actually keep track of blocks so we temporarily "forget" the tip.
                newServerTip = fromChainTip serverChainTip
            return (clientIdleRequestMoreN newClientTip newServerTip n)
        }

    clientIdleDoneN
        :: Nat n
        -> IO (ClientPipelinedStIdle n (BlockInMode CardanoMode) ChainPoint ChainTip IO ())
    clientIdleDoneN n = case n of
      Succ predN -> do
        putTextLn "Chain Sync: done! (Ignoring remaining responses)"
        return $ CollectResponse Nothing (clientNextDoneN predN) -- Ignore remaining message responses
      Zero -> do
        putTextLn "Chain Sync: done!"
        return $ SendMsgDone ()

    clientNextDoneN
        :: Nat n
        -> ClientStNext n (BlockInMode CardanoMode) ChainPoint ChainTip IO ()
    clientNextDoneN n =
      ClientStNext {
          recvMsgRollForward = \_ _ -> clientIdleDoneN n
        , recvMsgRollBackward = \_ _ -> clientIdleDoneN n
        }

    -- printBlock :: forall era. IsCardanoEra era => Block era -> IO ()
    printBlock :: forall era. Block era -> IO ()
    printBlock (Block (BlockHeader _ _ currBlockNo) transactions@([Tx era _])) = do

        let txBodies :: [TxBody era]
            txBodies = map getTxBody transactions

--        let txBodyToContent :: TxBody era -> _
--            txBodyToContent


        --let txCertificates :: [TxCertificates era]
        --    txCertificates = map TxCertificates transactions

        --let txBodyToContent :: TxBody era -> TxBodyContent era
        --    txBodyToContent = _


        --let fetchCertificates :: TxBody era -> [TxCertificates era]
        --    fetchCertificates (ByronTxBody {})= []
        --    fetchCertificates (ShelleyTxBody txBody _) = []

        --let txCertificates :: [TxCertificates era]
        --    txCertificates = map txCertificates txBodies

        --when (isJust $ certificatesSupportedInEra (cardanoEra :: CardanoEra era)) $
        --    panic "Not supported!"

        --txMetadataSupportedInEra
        putStrLn $ show currBlockNo ++ " transactions: " ++ show txBodies

    fromChainTip :: ChainTip -> WithOrigin BlockNo
    fromChainTip ct = case ct of
      ChainTipAtGenesis -> Origin
      ChainTip _ _ bno -> At bno

  return (clientIdleRequestMoreN Origin Origin Zero)
