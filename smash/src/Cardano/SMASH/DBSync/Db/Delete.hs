{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies     #-}

module Cardano.SMASH.DBSync.Db.Delete
  ( deleteDelistedPool
  , deleteRetiredPool
  , deleteAdminUser
  , deleteCascadeSlotNo
  ) where

import           Cardano.Prelude                hiding (Meta)

import           Database.Persist.Sql           (SqlBackend, delete,
                                                 selectKeysList, (==.))

import           Cardano.SMASH.DBSync.Db.Schema
import qualified Cardano.SMASH.DBSync.Db.Types  as Types

-- | Delete a delisted pool if it exists. Returns 'True' if it did exist and has been
-- deleted and 'False' if it did not exist.
deleteDelistedPool :: MonadIO m => Types.PoolId -> ReaderT SqlBackend m Bool
deleteDelistedPool poolId = do
  keys <- selectKeysList [ DelistedPoolPoolId ==. poolId ] []
  mapM_ delete keys
  pure $ not (null keys)

-- | Delete a retired pool if it exists. Returns 'True' if it did exist and has been
-- deleted and 'False' if it did not exist.
deleteRetiredPool :: MonadIO m => Types.PoolId -> ReaderT SqlBackend m Bool
deleteRetiredPool poolId = do
  keys <- selectKeysList [ RetiredPoolPoolId ==. poolId ] []
  mapM_ delete keys
  pure $ not (null keys)

deleteAdminUser :: MonadIO m => AdminUser -> ReaderT SqlBackend m Bool
deleteAdminUser adminUser = do
  keys <- selectKeysList [ AdminUserUsername ==. adminUserUsername adminUser, AdminUserPassword ==. adminUserPassword adminUser ] []
  mapM_ delete keys
  pure $ not (null keys)

deleteCascadeSlotNo :: MonadIO m => Word64 -> ReaderT SqlBackend m Bool
deleteCascadeSlotNo slotNo = do
  keys <- selectKeysList [ BlockSlotNo ==. Just slotNo ] []
  mapM_ delete keys
  pure $ not (null keys)