-- Persistent generated migration.

CREATE FUNCTION migrate() RETURNS void AS $$
DECLARE
  next_version int ;
BEGIN
  SELECT stage_two + 1 INTO next_version FROM schema_version ;
  IF next_version = 5 THEN
    CREATe TABLE "blacklisted_pool"("id" SERIAL8  PRIMARY KEY UNIQUE,"hash" base16type NOT NULL);
    ALTER TABLE "blacklisted_pool" ADD CONSTRAINT "unique_blacklisted_pool" UNIQUE("hash");
    CREATe TABLE "admin_user"("id" SERIAL8  PRIMARY KEY UNIQUE,"username" VARCHAR NOT NULL,"password" VARCHAR NOT NULL);
    ALTER TABLE "admin_user" ADD CONSTRAINT "unique_admin_user" UNIQUE("username");
    -- Hand written SQL statements can be added here.
    UPDATE schema_version SET stage_two = 5 ;
    RAISE NOTICE 'DB has been migrated to stage_two version %', next_version ;
  END IF ;
END ;
$$ LANGUAGE plpgsql ;

SELECT migrate() ;

DROP FUNCTION migrate() ;
