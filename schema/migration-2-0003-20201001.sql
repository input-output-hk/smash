-- Persistent generated migration.

CREATE FUNCTION migrate() RETURNS void AS $$
DECLARE
  next_version int ;
BEGIN
  SELECT stage_two + 1 INTO next_version FROM schema_version ;
  IF next_version = 3 THEN
    ALTER TABLE "pool_metadata_reference" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "pool_metadata_reference" ALTER COLUMN "url" TYPE text;
    ALTER TABLE "pool_metadata_reference" ALTER COLUMN "hash" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "ticker_name" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "hash" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "metadata" TYPE text;
    ALTER TABLE "pool_metadata_fetch_error" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "pool_metadata_fetch_error" ALTER COLUMN "pool_hash" TYPE text;
    ALTER TABLE "delisted_pool" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "delisted_pool" ADD CONSTRAINT "unique_delisted_pool" UNIQUE("pool_id");
    ALTER TABLE "delisted_pool" DROP CONSTRAINT "unique_blacklisted_pool";
    ALTER TABLE "reserved_ticker" ALTER COLUMN "name" TYPE text;
    ALTER TABLE "reserved_ticker" ALTER COLUMN "pool_hash" TYPE text;
    -- Hand written SQL statements can be added here.
    UPDATE schema_version SET stage_two = 3 ;
    RAISE NOTICE 'DB has been migrated to stage_two version %', next_version ;
  END IF ;
END ;
$$ LANGUAGE plpgsql ;

SELECT migrate() ;

DROP FUNCTION migrate() ;
