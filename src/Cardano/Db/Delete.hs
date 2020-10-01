{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}

module Cardano.Db.Delete
  ( deleteDelistedPool
  ) where

import           Cardano.Prelude hiding (Meta)

import           Control.Monad.IO.Class (MonadIO)
import           Control.Monad.Trans.Reader (ReaderT)

import           Database.Persist.Class (AtLeastOneUniqueKey, Key, PersistEntityBackend,
                    getByValue, insert, checkUnique)
import           Database.Persist.Sql (SqlBackend, (==.), deleteCascade, selectKeysList)
import           Database.Persist.Types (entityKey)

import           Cardano.Db.Schema
import           Cardano.Db.Error
import qualified Cardano.Db.Types as Types

-- | Delete a delisted pool if it exists. Returns 'True' if it did exist and has been
-- deleted and 'False' if it did not exist.
deleteDelistedPool :: MonadIO m => Types.PoolId -> ReaderT SqlBackend m Bool
deleteDelistedPool poolId = do
  keys <- selectKeysList [ DelistedPoolPoolId ==. poolId ] []
  mapM_ deleteCascade keys
  pure $ not (null keys)

