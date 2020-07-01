-- Persistent generated migration.

CREATE FUNCTION migrate() RETURNS void AS $$
DECLARE
  next_version int ;
BEGIN
  SELECT stage_two + 1 INTO next_version FROM schema_version ;
  IF next_version = 2 THEN
    CREATe TABLE "pool_meta_data"("id" SERIAL8  PRIMARY KEY UNIQUE,"url" VARCHAR NOT NULL,"hash" hash32type NOT NULL);
    ALTER TABLE "pool_meta_data" ADD CONSTRAINT "unique_pool_meta_data" UNIQUE("hash");
    -- Hand written SQL statements can be added here.
    UPDATE schema_version SET stage_two = 2 ;
    RAISE NOTICE 'DB has been migrated to stage_two version %', next_version ;
  END IF ;
END ;
$$ LANGUAGE plpgsql ;

SELECT migrate() ;

DROP FUNCTION migrate() ;
