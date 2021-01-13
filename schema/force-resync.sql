-- Clear block information, force re-sync.
TRUNCATE pool_metadata;
TRUNCATE pool_metadata_reference CASCADE;
TRUNCATE pool;
TRUNCATE retired_pool;
TRUNCATE pool_metadata_fetch_error CASCADE;
TRUNCATE block;
