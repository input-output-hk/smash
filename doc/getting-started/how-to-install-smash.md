## How to Install SMASH

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
