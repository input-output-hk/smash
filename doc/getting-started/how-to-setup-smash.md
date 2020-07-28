## How to setup SMASH

### How to run it with the node

First run the node. The genesis should be generated from Nix. You can run smash with:
```
SMASHPGPASSFILE=./config/pgpass stack run smash-exe -- run-app-with-db-sync --config ../cardano-db-sync/config/testnet-config.yaml --genesis-file /nix/store/pdnsmv1gi6llr92fk7sgs3j2gcphm6fm-shelley-testnet-genesis.json --socket-path ../cardano-node/state-node-shelley_testnet/node.socket --schema-dir schema/
```

### How to test this works?

You can run the provided example and try out these commands (presuming you know what CURL is and how to use it).
```
curl --verbose --header "Content-Type: application/json" --request GET http://localhost:3000/api/v1/metadata/ed25519_pk1z2ffur59cq7t806nc9y2g64wa60pg5m6e9cmrhxz9phppaxk5d4sn8nsqg

curl --verbose --user ksaric:cirask --header "Content-Type: application/json" --request POST --data '{"blacklistPool":"xyz"}' http://localhost:3000/api/v1/blacklist
```

### What else do I need?

*YOU NEED TO SERVE IT BEHIND HTTPS!*
Please understand that it's unsafe otherwise since it's using Basic Auth, which is not protected in any way and is visible when interacting with the server via the regular HTTP protocol.

You need an HTTP server to serve it from and simply point to the application port.