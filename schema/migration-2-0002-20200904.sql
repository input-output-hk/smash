-- Persistent generated migration.

CREATE FUNCTION migrate() RETURNS void AS $$
DECLARE
  next_version int ;
BEGIN
  SELECT stage_two + 1 INTO next_version FROM schema_version ;
  IF next_version = 2 THEN
    ALTER TABLE "pool_metadata_reference" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "pool_metadata_reference" ALTER COLUMN "url" TYPE text;
    ALTER TABLE "pool_metadata_reference" ALTER COLUMN "hash" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "ticker_name" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "hash" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "metadata" TYPE text;
    CREATe TABLE "pool_metadata_fetch_error"("id" SERIAL8  PRIMARY KEY UNIQUE,"fetch_time" timestamp NOT NULL,"pool_id" text NOT NULL,"pool_hash" text NOT NULL,"pmr_id" INT8 NOT NULL,"fetch_error" VARCHAR NOT NULL,"retry_count" uinteger NOT NULL);
    ALTER TABLE "pool_metadata_fetch_error" ADD CONSTRAINT "unique_pool_metadata_fetch_error" UNIQUE("fetch_time","pool_id");
    ALTER TABLE "pool_metadata_fetch_error" ADD CONSTRAINT "pool_metadata_fetch_error_pmr_id_fkey" FOREIGN KEY("pmr_id") REFERENCES "pool_metadata_reference"("id");
    ALTER TABLE "delisted_pool" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "reserved_ticker" ALTER COLUMN "name" TYPE text;
    ALTER TABLE "reserved_ticker" ALTER COLUMN "pool_hash" TYPE text;
    -- Hand written SQL statements can be added here.
    UPDATE schema_version SET stage_two = 2 ;
    RAISE NOTICE 'DB has been migrated to stage_two version %', next_version ;
  END IF ;
END ;
$$ LANGUAGE plpgsql ;

SELECT migrate() ;

DROP FUNCTION migrate() ;
