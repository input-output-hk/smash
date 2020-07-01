-- Persistent generated migration.

CREATE FUNCTION migrate() RETURNS void AS $$
DECLARE
  next_version int ;
BEGIN
  SELECT stage_two + 1 INTO next_version FROM schema_version ;
  IF next_version = 3 THEN
    CREATe TABLE "block"("id" SERIAL8  PRIMARY KEY UNIQUE,"hash" hash32type NOT NULL,"epoch_no" uinteger NULL,"slot_no" uinteger NULL,"block_no" uinteger NULL);
    -- Hand written SQL statements can be added here.
    UPDATE schema_version SET stage_two = 3 ;
    RAISE NOTICE 'DB has been migrated to stage_two version %', next_version ;
  END IF ;
END ;
$$ LANGUAGE plpgsql ;

SELECT migrate() ;

DROP FUNCTION migrate() ;
