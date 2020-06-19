-- Persistent generated migration.

CREATE FUNCTION migrate() RETURNS void AS $$
DECLARE
  next_version int ;
BEGIN
  SELECT stage_two + 1 INTO next_version FROM schema_version ;
  IF next_version = 1 THEN
    CREATe TABLE "tx_metadata"("id" SERIAL8  PRIMARY KEY UNIQUE,"hash" base16type NOT NULL,"metadata" json NOT NULL);
    ALTER TABLE "tx_metadata" ADD CONSTRAINT "unique_tx_metadata" UNIQUE("hash");
    -- Hand written SQL statements can be added here.
    UPDATE schema_version SET stage_two = 1 ;
    RAISE NOTICE 'DB has been migrated to stage_two version %', next_version ;
  END IF ;
END ;
$$ LANGUAGE plpgsql ;

SELECT migrate() ;

DROP FUNCTION migrate() ;
