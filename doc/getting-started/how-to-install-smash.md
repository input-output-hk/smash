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