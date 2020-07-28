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
SMASHPGPASSFILE=./config/pgpass stack run smash-exe -- run-app-with-db-sync --config config.yaml --genesis-file genesis.json --socket-path node.socket --schema-dir schema/
```

## How to test this works?

You can run the provided example and try out these commands
```
curl --verbose --header "Content-Type: application/json" --request GET http://localhost:3000/api/v1/metadata/ed25519_pk1z2ffur59cq7t806nc9y2g64wa60pg5m6e9cmrhxz9phppaxk5d4sn8nsqg

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


