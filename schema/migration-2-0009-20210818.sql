-- Persistent generated migration.

CREATE FUNCTION migrate() RETURNS void AS $$
DECLARE
  next_version int ;
BEGIN
  SELECT stage_two + 1 INTO next_version FROM schema_version ;
  IF next_version = 9 THEN
    ALTER TABLE "schema_version" ALTER COLUMN "id" TYPE INT8;
    ALTER TABLE "pool_metadata_reference" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "pool_metadata_reference" ALTER COLUMN "url" TYPE text;
    ALTER TABLE "pool_metadata_reference" ALTER COLUMN "hash" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "ticker_name" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "hash" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "metadata" TYPE text;
    ALTER TABLE "pool_metadata" DROP CONSTRAINT "pool_metadata_pmr_id_fkey";
    ALTER TABLE "pool_metadata" ADD CONSTRAINT "pool_metadata_pmr_id_fkey" FOREIGN KEY("pmr_id") REFERENCES "pool_metadata_reference"("id") ON DELETE CASCADE  ON UPDATE RESTRICT;
    ALTER TABLE "pool" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "retired_pool" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "pool_metadata_fetch_error" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "pool_metadata_fetch_error" ALTER COLUMN "pool_hash" TYPE text;
    ALTER TABLE "pool_metadata_fetch_error" DROP CONSTRAINT "pool_metadata_fetch_error_pmr_id_fkey";
    ALTER TABLE "pool_metadata_fetch_error" ADD CONSTRAINT "pool_metadata_fetch_error_pmr_id_fkey" FOREIGN KEY("pmr_id") REFERENCES "pool_metadata_reference"("id") ON DELETE CASCADE  ON UPDATE RESTRICT;
    ALTER TABLE "delisted_pool" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "reserved_ticker" ALTER COLUMN "name" TYPE text;
    ALTER TABLE "reserved_ticker" ALTER COLUMN "pool_hash" TYPE text;
    -- Hand written SQL statements can be added here.
    UPDATE schema_version SET stage_two = 9 ;
    RAISE NOTICE 'DB has been migrated to stage_two version %', next_version ;
  END IF ;
END ;
$$ LANGUAGE plpgsql ;

SELECT migrate() ;

DROP FUNCTION migrate() ;
