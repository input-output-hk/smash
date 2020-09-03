# Stakepool Metadata Aggregation Server (SMASH)

## Overview

Cardano Shelley introduces the concept of stake pools - reliable server nodes that keep an aggregated stake of pool operators and delegators in a single entity. Stake pools are registered on-chain, and their on-chain data (such as information required to calculate rewards) is critical to the operation of the ledger. Stake pools also possess metadata that helps users to make a rational choice of a stake pool to delegate to. This metadata is stored off-chain as it might reflect sensitive content, and such an approach allows for a degree of decentralized censorship. 

On the other hand, off-chain metadata storage prerequisites a challenge of open access by different users. On-chain stake pool registrations contain an URL pointer to the off-chain metadata and a content hash that can be fetched from a specific stake pool. This might cause both performance and privacy issues. Another crucial aspect to address is the stake pool’s “ticker” name, which is the short name a stake pool is recognized by. Ticker names might reflect prominent brands or trademarks which should not be duplicated as this leads to confusion. Stake pool operators running multiple pools might want to use the same metadata for all their pools and then, this might also lead to these pools appearing with the same ticker name. 

Addressing performance and privacy issues, a stake pool metadata aggregation server (SMASH) is introduced. SMASH provides a higher level of metadata accountability and maintenance. It aggregates metadata from existing stake pools and provides an efficient way to fetch it and store it in a semi-centralized environment. This metadata can then be curated and reviewed by an operator for censorship via the delisting feature. In particular, stake pools with illegal content can be delisted, and disputes over offending stake pool ticker names or their disambiguation can be resolved. SMASH can be provided as a service to delegators, stake pool operators, exchanges, wallets, etc., enabling independent validation. Users (e.g. wallets, exchanges, etc.) can choose to interpret the non-availability of the metadata as an indication that the pool should not be listed. 

**SMASH Characteristics**

The metadata aggregation server possesses the following characteristic features:

- runs continuously and autonomously;
- follows the blockchain data to track the stake pool registration or re-registration;
- downloads stake pool metadata from on-chain locations;
- is robust against incorrectly configured or malicious metadata hosting (e.g. timeouts, resource limits);
- verifies metadata content against the on-chain registered hash;
- verifies the size is within the limits, and the content matches the necessary JSON scheme;
- serves requested metadata via an API to wallets and other users in a performant way, including for the case of incremental updates;
- indicates that metadata is not available in response to requests;
- serves the requested metadata preserving the content hash to be verified against the hash from the on-chain registration certificate;
- allows operators to delist stake pools;
- allows operators to configure, check and adjust their chosen policy via an appropriate interface without service interruptions;
- follows typical behaviours, e.g. configured via CLI and/or configuration file, stdout/stderr logging. 

## Prerequisites

SMASH relies on:

* The PostgreSQL library. This can be installed on Linux using e.g.  ``apt install libpq-dev``
* The PostgreSQL server. This can be installed on Linux using e.g. ``apt install postgresql``
* The ``cardano-db-sync`` package. This acts as a library for database support, hence, it is not necessary to install it separately.
* The ``cardano-node`` package. This provides the core Cardano node functionality and runs as a passive node.

These need to be downloaded and installed before building, installing and deploying SMASH. It is not necessary
to install the Cardano wallet or any other Cardano components.

## Installation

### Create a database (DB)

First, you need to create the database. You can provide your own path, the example will use the default location. We need the PostgreSQL database, which can be created with:
```
SMASHPGPASSFILE=config/pgpass ./scripts/postgresql-setup.sh --createdb
```
Run this command in case it needs to be recreated:
```
SMASHPGPASSFILE=config/pgpass ./scripts/postgresql-setup.sh --recreatedb
```

After that, run the migrations (if there are any):
```
SMASHPGPASSFILE=config/pgpass cabal run smash-exe -- run-migrations --mdir ./schema
```

You can run additional migration scripts if they need to be created:
```
SMASHPGPASSFILE=config/pgpass cabal run smash-exe -- create-migration --mdir ./schema
```

Run these commands to show all tables:
```
\dt
```

To show details about a specific table:
```
\d+ TABLE_NAME
```

For example:
```
\d+ block
```

You can dump the schema with:
```
pg_dump -c -s --no-owner cexplorer > cexplorer.sql
```

### Install SMASH

SMASH can be built and installed from the command line using "cabal" as follows:

```
cabal build smash
cabal install smash
```

You can also use `stack` if you prefer. For this, replace `cabal`commands with `stack` as in the examples, in case you are already using `cabal`.

## Metadata

*The metadata that is stored by SMASH is restricted to contain more than 512 bytes.*

Registered stake pools provide the following metadata:
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

More information about the pool metadata (the `PoolMetaData` record) can be found [here](https://github.com/input-output-hk/cardano-ledger-specs/blob/4458fdba7e2211f63e7f28ecd3f9b55b02eee071/shelley/chain-and-ledger/executable-spec/src/Shelley/Spec/Ledger/TxData.hs#L62) 

Stake pool metadata information can be also found in [The mainnet metadata Design Specification for Delegation and Incentives in Cardano](https://hydra.iohk.io/build/790053/download/1/delegation_design_spec.pdf) section 4.2 Stake Pool Metadata, p.30.

## How to run SMASH with the Cardano node

First, run the Cardano node as a relay, or passive node e.g.:
```
cardano-node --genesis-file genesis.json --socket-path node.socket --config config.yaml
```

You can then run ``smash`` using e.g:
```
SMASHPGPASSFILE=./config/pgpass cabal run smash-exe -- run-app-with-db-sync --config config.yaml --socket-path node.socket --schema-dir schema/
```
You can also run a mainnet node using a Nix command:
```
nix-build -A scripts.mainnet.node -o mainnet-node-local./mainnet-node-local
```

## What does SMASH do?

SMASH synchronizes with the blockchain and fetches the pool metadata off the chain. Then, it stores that metadata in the database and allows people/wallets/clients to check it.

From the HTTP API it supports the fetching of the metadata using:
```
curl --verbose --header "Content-Type: application/json" --request GET http://localhost:3100/api/v1/metadata/<POOL_ID>/<POOL_HASH>
```
Delisting can be done as follows (in case you are an administrator):
```
curl --verbose --header "Content-Type: application/json" --request PATCH --data '{"poolId":"<POOL_ID>"}' http://localhost:3100/api/v1/delist
```

From the CLI (Command Line Interface) you can use an additional command, which presumes you have to execute them from the server. 
You can insert a pool manually:
```
SMASHPGPASSFILE=config/pgpass cabal exec smash-exe -- insert-pool --metadata <POOL_JSON_FILE_PATH> --poolId "<POOL_ID>" --poolhash "<POOL_HASH>"
```

You can reserve a ticker:
```
SMASHPGPASSFILE=config/pgpass cabal run smash-exe -- reserve-ticker-name --tickerName "<TICKER_NAME>" --poolhash "<POOL_HASH>"
```

## How to test this?

Run commands provided in the example:
```
curl --verbose --header "Content-Type: application/json" --request GET http://localhost:3100/api/v1/metadata/062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7/2560993cf1b6f3f1ebde429f062ce48751ed6551c2629ce62e4e169f140a3524

curl --verbose --user ksaric:cirask --header "Content-Type: application/json" --request PATCH --data '{"poolId":"xyz"}' http://localhost:3100/api/v1/delist
```

## What else is important?

*YOU NEED TO SERVE IT BEHIND HTTPS*
Interacting with a server via a regular HTTP protocol is unsafe since it is using Basic Auth, which is not protected and is visible during such interaction. You need an HTTP server (Apache or Nginx e.g) that can be configured post installation to directly point to the application port.

## How to get the Swagger/OpenAPI info?

First, run the application. Then, go to the localhost and copy the content into an [editor](https://editor.swagger.io/). 

## How to use SMASH

## Inserting pool metadata

This is an example (the hash from Blake2 256):
```
SMASHPGPASSFILE=config/pgpass cabal exec smash-exe -- insert-pool --metadata test_pool.json --poolId "062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7" --poolhash "cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f"
```

## Testing delisting feature

If you find a pool hash that has been inserted, like in our example, '93b13334b5edf623fd4c7a716f3cf47be5baf7fb3a431c16ee07aab8ff074873', you can test the delisting by sending a PATCH on the delist endpoint.
```
curl -X PATCH -v http://localhost:3100/api/v1/delist -H 'content-type: application/json' -d '{"poolId": "062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7"}'
```

If you have Basic Auth enabled (replace with the username/pass for your DB):
```
curl -u ksaric:test -X PATCH -v http://localhost:3100/api/v1/delist -H 'content-type: application/json' -d '{"poolId": "062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7"}'
```

Fetching the pool:
```
curl -X GET -v http://localhost:3100/api/v1/metadata/062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7/cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f | jq .
```

## Basic Auth and DB

You need to have the flag for disabling Basic auth not enabled (disabled). After you run the migration scripts (see in this README examples), you can insert the user with the password in the DB:
```
INSERT INTO admin_user (username, password) VALUES ('ksaric', 'test');
```

Now you will be able to run your SMASH server with user authentication from DB. If you change your users/passwords, please restart the application since it takes a full restart for users to reload.

## Test script

Below is provided an example of how SMASH works:
```
SMASHPGPASSFILE=config/pgpass ./scripts/postgresql-setup.sh --recreatedb
SMASHPGPASSFILE=config/pgpass cabal run smash-exe -- run-migrations --mdir ./schema
SMASHPGPASSFILE=config/pgpass cabal run smash-exe -- create-migration --mdir ./schema
SMASHPGPASSFILE=config/pgpass cabal run smash-exe -- run-migrations --mdir ./schema

SMASHPGPASSFILE=config/pgpass cabal run smash-exe -- insert-pool --metadata test_pool.json --poolId "062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7" --poolhash "cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f"

SMASHPGPASSFILE=config/pgpass cabal run smash-exe -- run-app
```

After the server is running, you can check the hash on the localhost to see it return the JSON metadata.

## How to figure out the JSON hash?

You can use a cardano-cli command to fetch the stake pool metadata hash from a passive node. But also, you can figure out the JSON hash inside GHCi:

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

This assumes that you have a file called "test_pool.json" in your current directory that contains the JSON metadata for the stake pool.

## How to insert the reserved ticker name?

Currently, SMASH service works by allowing users to insert the ticker name and the hash of the pool they want to be reserved _for that ticker name_.

There is a CLI utility for doing exactly that. If you want to reserve the ticker name "SALAD" for the specific metadata hash "2560993cf1b6f3f1ebde429f062ce48751ed6551c2629ce62e4e169f140a3524", then you would reserve it like this:
```
SMASHPGPASSFILE=config/pgpass cabal run smash-exe -- reserve-ticker-name --tickerName "SALAD" --poolhash "2560993cf1b6f3f1ebde429f062ce48751ed6551c2629ce62e4e169f140a3524"
```

If somebody adds the ticker name that exists there, it will not be returned, but it will return 404.

## How to test delisting?

The example we used for testing shows that we can delist the pool id. That pool id is then unable to provide any more pools.

We first insert the `test_pool.json` we have in the provided example:
```
SMASHPGPASSFILE=config/pgpass cabal run smash-exe -- insert-pool --metadata test_pool.json --poolId "062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7" --poolhash "cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f"
```

Then we change the ticker name of `test_pool.json` from `testy` to `testo`. This changes the pool hash. You can check the hash using the example in https://github.com/input-output-hk/smash#how-to-figure-out-the-json-hash:
```
SMASHPGPASSFILE=config/pgpass cabal run smash-exe -- insert-pool --metadata test_pool.json --poolId "062693863e0bcf9f619238f020741381d4d3748aae6faf1c012e80e7" --poolhash "3b842358a698119a4b0c0f4934d26cff69190552bf47a85f40f5d1d646c82699"
```

We now have two pools from the same pool id. Run this to see if they are in the database: 
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

This assumes that you have a file called "test_pool.json" in your current directory that contains the JSON metadata for the stake pool.
