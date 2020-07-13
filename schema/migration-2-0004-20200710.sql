-- Persistent generated migration.

CREATE FUNCTION migrate() RETURNS void AS $$
DECLARE
  next_version int ;
BEGIN
  SELECT stage_two + 1 INTO next_version FROM schema_version ;
  IF next_version = 4 THEN
    ALTER TABLE "block" ADD CONSTRAINT "unique_block" UNIQUE("hash");
    CREATe TABLE "meta"("id" SERIAL8  PRIMARY KEY UNIQUE,"protocol_const" INT8 NOT NULL,"slot_duration" INT8 NOT NULL,"start_time" timestamp NOT NULL,"slots_per_epoch" INT8 NOT NULL,"network_name" VARCHAR NULL);
    ALTER TABLE "meta" ADD CONSTRAINT "unique_meta" UNIQUE("start_time");
    -- Hand written SQL statements can be added here.
    UPDATE schema_version SET stage_two = 4 ;
    RAISE NOTICE 'DB has been migrated to stage_two version %', next_version ;
  END IF ;
END ;
$$ LANGUAGE plpgsql ;

SELECT migrate() ;

DROP FUNCTION migrate() ;
