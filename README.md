# Stakepool Metadata Aggregation Server (SMASH)

[![Coverage Status](https://coveralls.io/repos/github/input-output-hk/smash/badge.svg?branch=master)](https://coveralls.io/github/input-output-hk/smash?branch=master)

This repository contains the source code for the Cardano Stakepool Metadata Aggregation Server (SMASH).
The purpose of SMASH is to aggregate common metadata about stakepools that are registered
on the Cardano blockchain, including the name of the stakepool, its "ticker" name etc.
This metadata can be curated and provided as a service to delegators, stake pool operators,
exchanges etc., enabling independent validation and/or disambiguation of stakepool "ticker" names, for example.

## Installation

SMASH can be built and installed from the command line using "cabal" as follows:

```
cabal build smash
cabal install smash
```

### Prerequsites

SMASH relies on:

* The PostgreSQL library.  This can be installed on Linux using e.g. ``apt install libpg-dev``
* The PostgreSQL server.  This can be installed on Linux using e.g. ``apt install pg``
* The ``cardano-db-sync`` package.  This provides necessary database support.
* The ``cardano-db-node`` package.  This provides the core Cardano node functionality.
* An HTTP server (e.g. Apache).

These need to be downloaded and installed before building, installing and deploying SMASH.  It is not necessary
to install the Cardano wallet or any other Cardano components.

## Metadata

*The metadata that is stored by SMASH is restricted to contain no more than 512 bytes.*

Registered stake pools provide the following on-chain data:
* owner
* pool name
* pool ticker
* homepage
* pledge address
* short description

SMASH records and serves the following subset of information:
* pool name
* pool ticker
* homepage
* short description

More information about the pool metadata (the `PoolMetaData` record) can be found here - https://github.com/input-output-hk/cardano-ledger-specs/blob/4458fdba7e2211f63e7f28ecd3f9b55b02eee071/shelley/chain-and-ledger/executable-spec/src/Shelley/Spec/Ledger/TxData.hs#L62

Information about the structure of the (current) stake pool metadata can be found at - https://github.com/cardano-foundation/incentivized-testnet-stakepool-registry#submission-well-formedness-rules

The most important parts of this information are:
```JSON
{
   "owner":{
      "type":"string",
      "format":"bech32",
      "pattern":"^ed25519_pk1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]+$",
      "maxLength":70
   },
   "name":{
      "type":"string",
      "minLength":1,
      "maxLength":50
   },
   "description":{
      "type":"string",
      "minLength":1,
      "maxLength":255
   },
   "ticker":{
      "type":"string",
      "minLength":3,
      "maxLength":5,
      "pattern":"^[A-Z0-9]{3,5}$"
   },
   "homepage":{
      "type":"string",
      "format":"uri",
      "pattern":"^https://"
   },
   "pledge_address":{
      "type":"string",
      "format":"bech32",
      "pattern":"^addr1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]+$",
      "maxLength":64
   }
}
```

70+50+255+5+64 = 444 bytes.

## How to run SMASH with the Cardano node

First run the Cardano node as a relay, e.g.:

```
cardano-node --genesis-file genesis.json --socket-path node.socket --config config.yaml
```

You can then run ``smash`` using e.g:
```
SMASHPGPASSFILE=./config/pgpass stack run smash-exe -- run-app-with-db-sync --config config.yaml --socket-path node.socket --schema-dir schema/
```

## How to test this works?

You can run the provided example and try out these commands
```
curl --verbose --header "Content-Type: application/json" --request GET http://localhost:3100/api/v1/metadata/062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7/2560993cf1b6f3f1ebde429f062ce48751ed6551c2629ce62e4e169f140a3524

curl --verbose --user ksaric:cirask --header "Content-Type: application/json" --request POST --data '{"delistPool":"xyz"}' http://localhost:3000/api/v1/delist
```

## What else do I need?

*YOU NEED TO SERVE IT BEHIND HTTPS!*
Please understand that it's unsafe otherwise since it's using Basic Auth, which is not protected in any way and is visible when interacting with the server via the regular HTTP protocol.

You need an HTTP server to serve it from and simply point to the application port.

## How to get the Swagger/OpenAPI info?

Run the application, go to the local port http://localhost:3000/swagger.json and copy the content into https://editor.swagger.io/
Voila! You got it, the spec is there.

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
stack exec smash-exe -- insert-pool --metadata test_pool.json --poolId "062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7" --poolhash "cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f"
```

## Test delisting

If you find some pool hash that has been inserted, like in our example, '93b13334b5edf623fd4c7a716f3cf47be5baf7fb3a431c16ee07aab8ff074873'.

You can test the delisting by sending a PATCH on the delist endpoint.
```
curl -X PATCH -v http://localhost:3100/api/v1/delist -H 'content-type: application/json' -d '{"poolId": "062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7"}'
```

Or if you have Basic Auth enabled (replace with the username/pass for your DB):
```
curl -u ksaric:test -X PATCH -v http://localhost:3100/api/v1/delist -H 'content-type: application/json' -d '{"poolId": "062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7"}'
```

Fetching the pool:
```
curl -X GET -v http://localhost:3100/api/v1/metadata/062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7/cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f | jq .
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

SMASHPGPASSFILE=config/pgpass stack run smash-exe -- insert-pool --metadata test_pool.json --poolId "062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7" --poolhash "cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f"

SMASHPGPASSFILE=config/pgpass stack run smash-exe -- run-app
```

After the server is running, you can check the hash on http://localhost:3100/api/v1/metadata/062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7/cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f to see it return the JSON metadata.

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


## How to insert the reserved ticker name?

Currently, the SMASH service works by allowing superusers to insert the ticker name and the hash of the pool they want to be reserved _for that ticker name_.

There is a CLI utility for doing exactly that. If you want to reserve the ticker name "SALAD" for the specific metadata hash "2560993cf1b6f3f1ebde429f062ce48751ed6551c2629ce62e4e169f140a3524", then you would reserve it like this:
```
SMASHPGPASSFILE=config/pgpass stack run smash-exe -- insert-ticker-name --tickerName "SALAD" --poolhash "2560993cf1b6f3f1ebde429f062ce48751ed6551c2629ce62e4e169f140a3524"
```

If somebody adds the ticker name that exists there, it will not be returned, but it will return 404.

## How to test delisting?

The example we used for testing shows that we can delist the pool id.
That pool id is then unable to provide any more pools.

We first insert the `test_pool.json` we have in the provided example:
```
SMASHPGPASSFILE=config/pgpass stack run smash-exe -- insert-pool --metadata test_pool.json --poolId "062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7" --poolhash "cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f"
```

Then we change ticker name of `test_pool.json` from `testy` to `testo`. This changes the pool hash.
You can check the hash using the example in https://github.com/input-output-hk/smash#how-to-figure-out-the-json-hash:
```
SMASHPGPASSFILE=config/pgpass stack run smash-exe -- insert-pool --metadata test_pool.json --poolId "062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7" --poolhash "3b842358a698119a4b0c0f4934d26cff69190552bf47a85f40f5d1d646c82699"
```

We now have two pools from the same pool id. Let's see if we got them in the database: 
```
curl -X GET -v http://localhost:3100/api/v1/metadata/062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7/cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f | jq .

curl -X GET -v http://localhost:3100/api/v1/metadata/062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7/3b842358a698119a4b0c0f4934d26cff69190552bf47a85f40f5d1d646c82699 | jq .
```
We can try to delist that pool id and then try fetching both pools to see if delisting works on the level of the pool id:
```
curl -X PATCH -v http://localhost:3100/api/v1/delist -H 'content-type: application/json' -d '{"poolId": "062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7"}'
```

Fetching them again should result in 403:
```
curl -X GET -v http://localhost:3100/api/v1/metadata/062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7/cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f | jq .

curl -X GET -v http://localhost:3100/api/v1/metadata/062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7/3b842358a698119a4b0c0f4934d26cff69190552bf47a85f40f5d1d646c82699 | jq .
```

