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




