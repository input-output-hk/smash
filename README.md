# smash

[![Coverage Status](https://coveralls.io/repos/github/input-output-hk/smash/badge.svg?branch=master)](https://coveralls.io/github/input-output-hk/smash?branch=master)

This is the repository that takes care of the cardano node Stakepool Metadata Aggregation Server.

*The metadata is restricted to have no more than 512 bytes.*

The list of fields we need to have from the stake pool are:
* owner
* name
* ticker
* homepage
* pledge address
* short description

The ones we have to store offline, on this service are:
* name
* ticker
* homepage
* short description

The one remaining on the chain are:
* owner
* pledge address

The information about the `PoolMetaData` can be found here - https://github.com/input-output-hk/cardano-ledger-specs/blob/4458fdba7e2211f63e7f28ecd3f9b55b02eee071/shelley/chain-and-ledger/executable-spec/src/Shelley/Spec/Ledger/TxData.hs#L62

There is information about the structure of the (current) stake pool information - https://github.com/cardano-foundation/incentivized-testnet-stakepool-registry#submission-well-formedness-rules

The most important points of it are here:
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

## How to run it with the node

First run the node. The genesis should be generated from Nix. You can run smash with:
```
SMASHPGPASSFILE=./config/pgpass stack run smash-exe -- run-app-with-db-sync --config ../cardano-db-sync/config/testnet-config.yaml --genesis-file /nix/store/pdnsmv1gi6llr92fk7sgs3j2gcphm6fm-shelley-testnet-genesis.json --socket-path ../cardano-node/state-node-shelley_testnet/node.socket --schema-dir schema/
```

## How to test this works?

You can run the provided example and try out these commands (presuming you know what CURL is and how to use it).
```
curl --verbose --header "Content-Type: application/json" --request GET http://localhost:3000/api/v1/metadata/ed25519_pk1z2ffur59cq7t806nc9y2g64wa60pg5m6e9cmrhxz9phppaxk5d4sn8nsqg

curl --verbose --user ksaric:cirask --header "Content-Type: application/json" --request POST --data '{"blacklistPool":"xyz"}' http://localhost:3000/api/v1/blacklist
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

## Test blacklisting

If you find some pool hash that has been inserted, like in our example, '93b13334b5edf623fd4c7a716f3cf47be5baf7fb3a431c16ee07aab8ff074873'.

You can test the blacklisting by sending a PATCH on the blacklist endpoint.
```
curl -X PATCH -v http://localhost:3100/api/v1/blacklist -H 'content-type: application/json' -d '{"poolHash": "93b13334b5edf623fd4c7a716f3cf47be5baf7fb3a431c16ee07aab8ff074873"}'
```

Or if you have Basic Auth enabled (replace with you username/pass you have in your DB):
```
curl -u ksaric:cirask -X PATCH -v http://localhost:3100/api/v1/blacklist -H 'content-type: application/json' -d '{"poolHash": "93b13334b5edf623fd4c7a716f3cf47be5baf7fb3a431c16ee07aab8ff074873"}'
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

An example of how the whole thing works.
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
So run GHCi, using whatever you please (I will be using `stack ghci`) and:
```
import qualified Cardano.Crypto.Hash.Class as Crypto
import qualified Cardano.Crypto.Hash.Blake2b as Crypto
import qualified Data.ByteString.Base16 as B16

poolMetadata <- readFile "test_pool.json"
B16.encode $ Crypto.digest (Proxy :: Proxy Crypto.Blake2b_256) (encodeUtf8 poolMetadata)
```

This presumes that you have a file containing the JSON in your path called "test_pool.json".

