-- Persistent generated migration.

CREATE FUNCTION migrate() RETURNS void AS $$
DECLARE
  next_version int ;
BEGIN
  SELECT stage_two + 1 INTO next_version FROM schema_version ;
  IF next_version = 1 THEN
    CREATe TABLE "pool_metadata"("id" SERIAL8  PRIMARY KEY UNIQUE,"pool_id" text NOT NULL,"ticker_name" text NOT NULL,"hash" base16type NOT NULL,"metadata" text NOT NULL);
    ALTER TABLE "pool_metadata" ADD CONSTRAINT "unique_pool_metadata" UNIQUE("pool_id","hash");
    CREATe TABLE "pool_metadata_reference"("id" SERIAL8  PRIMARY KEY UNIQUE,"pool_id" text NOT NULL,"url" text NOT NULL,"hash" base16type NOT NULL);
    ALTER TABLE "pool_metadata_reference" ADD CONSTRAINT "unique_pool_metadata_reference" UNIQUE("pool_id","hash");
    CREATe TABLE "pool"("id" SERIAL8  PRIMARY KEY UNIQUE,"pool_id" INT8 NOT NULL);
    ALTER TABLE "pool" ADD CONSTRAINT "unique_pool_id" UNIQUE("pool_id");
    ALTER TABLE "pool" ADD CONSTRAINT "pool_pool_id_fkey" FOREIGN KEY("pool_id") REFERENCES "pool"("id");
    CREATe TABLE "block"("id" SERIAL8  PRIMARY KEY UNIQUE,"hash" hash32type NOT NULL,"epoch_no" uinteger NULL,"slot_no" uinteger NULL,"block_no" uinteger NULL);
    ALTER TABLE "block" ADD CONSTRAINT "unique_block" UNIQUE("hash");
    CREATe TABLE "meta"("id" SERIAL8  PRIMARY KEY UNIQUE,"protocol_const" INT8 NOT NULL,"slot_duration" INT8 NOT NULL,"start_time" timestamp NOT NULL,"slots_per_epoch" INT8 NOT NULL,"network_name" VARCHAR NULL);
    ALTER TABLE "meta" ADD CONSTRAINT "unique_meta" UNIQUE("start_time");
    CREATe TABLE "blacklisted_pool"("id" SERIAL8  PRIMARY KEY UNIQUE,"pool_id" hash28type NOT NULL);
    ALTER TABLE "blacklisted_pool" ADD CONSTRAINT "unique_blacklisted_pool" UNIQUE("pool_id");
    CREATe TABLE "reserved_ticker"("id" SERIAL8  PRIMARY KEY UNIQUE,"name" text NOT NULL,"pool_hash" base16type NOT NULL);
    ALTER TABLE "reserved_ticker" ADD CONSTRAINT "unique_reserved_ticker" UNIQUE("name");
    CREATe TABLE "admin_user"("id" SERIAL8  PRIMARY KEY UNIQUE,"username" VARCHAR NOT NULL,"password" VARCHAR NOT NULL);
    ALTER TABLE "admin_user" ADD CONSTRAINT "unique_admin_user" UNIQUE("username");
    -- Hand written SQL statements can be added here.
    UPDATE schema_version SET stage_two = 1 ;
    RAISE NOTICE 'DB has been migrated to stage_two version %', next_version ;
  END IF ;
END ;
$$ LANGUAGE plpgsql ;

SELECT migrate() ;

DROP FUNCTION migrate() ;
