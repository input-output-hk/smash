-- Persistent generated migration.

CREATE FUNCTION migrate() RETURNS void AS $$
DECLARE
  next_version int ;
BEGIN
  SELECT stage_two + 1 INTO next_version FROM schema_version ;
  IF next_version = 2 THEN
    ALTER TABLE "pool_metadata_reference" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "pool_metadata_reference" ALTER COLUMN "url" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "pool_id" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "ticker_name" TYPE text;
    ALTER TABLE "pool_metadata" ALTER COLUMN "metadata" TYPE text;
    ALTER TABLE "pool_metadata" ADD COLUMN "pmr_id" INT8 NOT NULL;
    ALTER TABLE "reserved_ticker" ALTER COLUMN "name" TYPE text;
    -- Hand written SQL statements can be added here.
    UPDATE schema_version SET stage_two = 2 ;
    RAISE NOTICE 'DB has been migrated to stage_two version %', next_version ;
  END IF ;
END ;
$$ LANGUAGE plpgsql ;

SELECT migrate() ;

DROP FUNCTION migrate() ;
