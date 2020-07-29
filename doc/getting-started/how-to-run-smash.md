## How to run

### Create DB

You first need to create the database. You can provide your own path, the example will use the default location. We need the PostgreSQL database and we create it with:
```
SMASHPGPASSFILE=config/pgpass ./scripts/postgresql-setup.sh --createdb
```
Or if it needs to be recreated:
```
SMASHPGPASSFILE=config/pgpass ./scripts/postgresql-setup.sh --recreatedb
```

After that we need to run the migrations (if there are any):
```
SMASHPGPASSFILE=config/pgpass stack run smash-exe -- run-migrations --mdir ./schema
```

And after that we can run additional migration scripts if they need to be created:
```
SMASHPGPASSFILE=config/pgpass stack run smash-exe -- create-migration --mdir ./schema
```

To show all tables:
```
\dt
```

To show details about specific table:
```
\d+ TABLE_NAME
```

For example:
```
\d+ block
```

Dumping the schema:
```
pg_dump -c -s --no-owner cexplorer > cexplorer.sql
```

## Inserting pool metadata


This is an example (we got the hash from Blake2 256):
```
stack exec smash-exe -- insert-pool --metadata test_pool.json --poolhash "cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f"
```

## Test delisting

If you find some pool hash that has been inserted, like in our example, '93b13334b5edf623fd4c7a716f3cf47be5baf7fb3a431c16ee07aab8ff074873'.

You can test the delisting by sending a PATCH on the delist endpoint.
```
curl -X PATCH -v http://localhost:3100/api/v1/delist -H 'content-type: application/json' -d '{"poolHash": "93b13334b5edf623fd4c7a716f3cf47be5baf7fb3a431c16ee07aab8ff074873"}'
```

Or if you have Basic Auth enabled (replace with the username/pass for your DB):
```
curl -u ksaric:cirask -X PATCH -v http://localhost:3100/api/v1/delist -H 'content-type: application/json' -d '{"poolHash": "93b13334b5edf623fd4c7a716f3cf47be5baf7fb3a431c16ee07aab8ff074873"}'
```

Fetching the pool:
```
curl -X GET -v http://localhost:3100/api/v1/metadata/93b13334b5edf623fd4c7a716f3cf47be5baf7fb3a431c16ee07aab8ff074873 | jq .
```

## Basic Auth and DB

You need to have the flag for disabling Basic auth not enabled (disabled).
After you run the migration scripts (see in this README examples), you can simply insert the user with the password in the DB:
```
INSERT INTO admin_user (username, password) VALUES ('ksaric', 'test');
```

That is it, you will now be able to run you SMASH server with user authentification from DB.
If you change your users/passwords, please restart the application since it takes a full restart for users to reload.

## Test script

An example of how SMASH works.
```
SMASHPGPASSFILE=config/pgpass ./scripts/postgresql-setup.sh --recreatedb
SMASHPGPASSFILE=config/pgpass stack run smash-exe -- run-migrations --mdir ./schema
SMASHPGPASSFILE=config/pgpass stack run smash-exe -- create-migration --mdir ./schema
SMASHPGPASSFILE=config/pgpass stack run smash-exe -- run-migrations --mdir ./schema

SMASHPGPASSFILE=config/pgpass stack run smash-exe -- insert-pool --metadata test_pool.json --poolhash "cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f"

SMASHPGPASSFILE=config/pgpass stack run smash-exe -- run-app
```

After the server is running, you can check the hash on http://localhost:3100/api/v1/metadata/cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f to see it return the JSON metadata.

## How to figure out the JSON hash?

You can do it inside GHCi.
```
ghci
```

```
Prelude> import qualified Cardano.Crypto.Hash.Class as Crypto
Prelude> import qualified Cardano.Crypto.Hash.Blake2b as Crypto
Prelude> import qualified Data.ByteString.Base16 as B16

Prelude> poolMetadata <- readFile "test_pool.json"
Prelude> B16.encode $ Crypto.digest (Proxy :: Proxy Crypto.Blake2b_256) (encodeUtf8 poolMetadata)
```

This assumes that you have a file called "test_pool.json" in your current directory that contains the JSON
metadata for the stake pool.

