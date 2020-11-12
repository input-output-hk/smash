{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}

-- Yes, yes, this is an exception.
{-# OPTIONS_GHC -fno-warn-orphans #-}

module SmashSpecSM
    ( smashSpecSM
    ) where

import           Cardano.Prelude
import           Prelude (Show (..))

import           Data.TreeDiff (ToExpr (..), Expr (..))
import qualified Data.Map as Map
import           Data.IORef (newIORef)

import           Test.Hspec (Spec, describe, it)

import           Test.QuickCheck (Gen, Property, oneof, (===), elements, listOf)
import           Test.QuickCheck.Monadic (monadicIO, run)

import           Test.StateMachine
import           Test.StateMachine.Types
import qualified Test.StateMachine.Types.Rank2 as Rank2

import           Cardano.SMASH.Lib
import           Cardano.SMASH.Types
import           Cardano.SMASH.DB

-- Ewwww. Should be burned.
import           System.IO.Unsafe (unsafePerformIO)

-------------------------------------------------------------------------------
-- Tests
-------------------------------------------------------------------------------

-- This is currently just checking that it inserts a pool into a model.
smashSpecSM :: Spec
smashSpecSM = do
    describe "SMASH state machine" $ do
        it "HULK should SMASH the state machine" $ do
            prop_smash

prop_smash :: Property
prop_smash = do

    forAllCommands smUnused (Just 100) $ \cmds -> monadicIO $ do

        --TODO(KS): Initialize the REAL DB!
        dataLayer <- run createStubbedDataLayer

        -- Run the actual commands
        (hist, _model, res) <- runCommands (smashSM dataLayer) cmds

        -- Pretty the commands
        prettyCommands (smashSM dataLayer) hist $ checkCommandNames cmds (res === Ok)

smUnused :: StateMachine Model Action IO Response
smUnused = smashSM $ unsafePerformIO createStubbedDataLayer

---- | Weird, but ok.
--smUnused :: DataLayer -> StateMachine Model Action IO Response
--smUnused dataLayer = smashSM dataLayer

--initialModel :: Model r
--initialModel = DBModel [] [] [] [] [] [] [] []

data DBModel = DBModel
    { poolsMetadata         :: [(Text, Text)]
    , metadataReferences    :: [PoolMetadataReferenceId]
    , reservedTickers       :: [ReservedTickerId]
    , delistedPools         :: [PoolId]
    , retiredPools          :: [PoolId]
    , adminUsers            :: [AdminUser]
    , fetchErrors           :: [PoolFetchError]
    }

-------------------------------------------------------------------------------
-- Language
-------------------------------------------------------------------------------

-- | The list of commands/actions the model can take.
-- The __r__ type here is the polymorphic type param for symbolic and concrete @Action@.
data Action (r :: Type -> Type)
    = InsertPool !PoolId !PoolMetadataHash !PoolMetadataRaw
    -- ^ This should really be more type-safe.
    deriving (Show, Generic1, Rank2.Foldable, Rank2.Traversable, Rank2.Functor, CommandNames)

-- | The types of responses of the model.
-- The __r__ type here is the polymorphic type param for symbolic and concrete @Response@.
data Response (r :: Type -> Type)
    = PoolInserted !PoolId !PoolMetadataHash !PoolMetadataRaw
    | MissingPoolHash !PoolId !PoolMetadataHash
    deriving (Show, Generic1, Rank2.Foldable, Rank2.Traversable, Rank2.Functor)

-- | The types of error that can occur in the model.
data Error
    = ExitCodeError ExitCode
    | UnexpectedError
    deriving (Show)

-- | Do we need this instance?
instance Exception Error

-------------------------------------------------------------------------------
-- Instances
-------------------------------------------------------------------------------

deriving instance ToExpr (Model Concrete)

-- No way to convert this.
instance ToExpr DataLayer where
    toExpr dataLayer = Rec "DataLayer" (Map.empty)

-------------------------------------------------------------------------------
-- The model we keep track of
-------------------------------------------------------------------------------

-- AND. Logic. N stuff.
instance Eq DataLayer where
     _ == _ = True

instance Show DataLayer where
    show _ = "DataLayer"

-- | The model contains the data.
data Model (r :: Type -> Type) = RunningModel !DataLayer
    deriving (Eq, Show, Generic)

-- | Initially, we don't have any exit codes in the protocol.
initialModel :: DataLayer -> Model r
initialModel dataLayer = RunningModel dataLayer

-------------------------------------------------------------------------------
-- State machine
-------------------------------------------------------------------------------

smashSM :: DataLayer -> StateMachine Model Action IO Response
smashSM dataLayer = StateMachine
    { initModel     = initialModel dataLayer
    , transition    = mTransitions
    , precondition  = mPreconditions
    , postcondition = mPostconditions
    , generator     = mGenerator
    , invariant     = Nothing
    , shrinker      = mShrinker
    , semantics     = mSemantics
    , mock          = mMock
    , distribution  = Nothing
    }
  where
    -- | Let's handle ju
    mTransitions :: Model r -> Action r -> Response r -> Model r
    mTransitions m@(RunningModel model) action response = m

    -- | Preconditions for this model.
    -- No preconditions?
    mPreconditions :: Model Symbolic -> Action Symbolic -> Logic
    mPreconditions (RunningModel model) _ = Top

    -- | Post conditions for the system.
    mPostconditions :: Model Concrete -> Action Concrete -> Response Concrete -> Logic
    mPostconditions _ (InsertPool poolId poolHash poolOfflineMeta) (PoolInserted poolId' poolHash' poolOfflineMeta')   = Top
    mPostconditions _ _                                     _                                           = Bot

    -- | Generator for symbolic actions.
    mGenerator :: Model Symbolic -> Maybe (Gen (Action Symbolic))
    mGenerator _            = Just $ oneof
        [ InsertPool <$> genPoolId <*> genPoolHash <*> genPoolOfflineMetadataText
        ]

    -- | Trivial shrinker. __No shrinker__.
    mShrinker :: Model Symbolic -> Action Symbolic -> [Action Symbolic]
    mShrinker _ _ = []

    -- | Here we'd do the dispatch to the actual SUT.
    mSemantics :: Action Concrete -> IO (Response Concrete)
    mSemantics (InsertPool poolId poolHash poolOfflineMeta) = do
        let addPoolMetadata = dlAddPoolMetadata dataLayer
        -- TODO(KS): Fix this.
        result <- addPoolMetadata Nothing poolId poolHash poolOfflineMeta (PoolTicker "tickerName")
        case result of
            Left err -> return $ MissingPoolHash poolId poolHash
            Right poolOfflineMeta' -> return $ PoolInserted poolId poolHash poolOfflineMeta'

    -- | Compare symbolic and SUT.
    mMock :: Model Symbolic -> Action Symbolic -> GenSym (Response Symbolic)
    mMock _ (InsertPool poolId poolHash poolOfflineMeta)   = return (PoolInserted poolId poolHash poolOfflineMeta)
    --mMock _ (MissingPoolHash _)    = return PoolInserted

-- | A simple utility function so we don't have to pass panic around.
doNotUse :: a
doNotUse = panic "Should not be used!"

genPoolId :: Gen PoolId
genPoolId = PoolId <$> genSafeText

genPoolHash :: Gen PoolMetadataHash
genPoolHash = PoolMetadataHash <$> genSafeText

-- |Improve this.
genPoolOfflineMetadataText :: Gen PoolMetadataRaw
genPoolOfflineMetadataText = PoolMetadataRaw <$> genSafeText

genSafeChar :: Gen Char
genSafeChar = elements ['a'..'z']

genSafeText :: Gen Text
genSafeText = toS <$> listOf genSafeChar

