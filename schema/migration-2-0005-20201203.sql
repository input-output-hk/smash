-- Persistent generated migration.

CREATE FUNCTION migrate() RETURNS void AS $$
DECLARE
  next_version int ;
BEGIN
  SELECT stage_two + 1 INTO next_version FROM schema_version ;
  IF next_version = 5 THEN
    ALTER TABLE "pool_metadata_fetch_error" DROP CONSTRAINT "unique_pool_metadata_fetch_error";
    ALTER TABLE "pool_metadata_fetch_error" ADD CONSTRAINT "unique_pool_metadata_fetch_error" UNIQUE("fetch_time","pool_id","pool_hash","retry_count");
    -- Hand written SQL statements can be added here.
    UPDATE schema_version SET stage_two = 5 ;
    RAISE NOTICE 'DB has been migrated to stage_two version %', next_version ;
  END IF ;
END ;
$$ LANGUAGE plpgsql ;

SELECT migrate() ;

DROP FUNCTION migrate() ;
