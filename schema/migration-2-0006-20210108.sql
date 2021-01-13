-- Persistent generated migration.

CREATE FUNCTION migrate() RETURNS void AS $$
DECLARE
  next_version int ;
BEGIN
  SELECT stage_two + 1 INTO next_version FROM schema_version ;
  IF next_version = 6 THEN
    -- Fix the pool table.
    DROP TABLE "pool";
    CREATe TABLE "pool"("id" SERIAL8  PRIMARY KEY UNIQUE,"pool_id" text NOT NULL);
    ALTER TABLE "pool" ADD CONSTRAINT "unique_pool_id" UNIQUE("pool_id");
    -- Hand written SQL statements can be added here.
    UPDATE schema_version SET stage_two = 6 ;
    RAISE NOTICE 'DB has been migrated to stage_two version %', next_version ;
  END IF ;
END ;
$$ LANGUAGE plpgsql ;

SELECT migrate() ;

DROP FUNCTION migrate() ;
