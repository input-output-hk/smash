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

