# Running the SMASH server

There is an order of how to run the SMASH service.
It requires the node to be run first, since it fetches the blocks and online info from the blockchain 
in the node.
It also requires the Postgresql database to be running.
After the Postgresql database is installed, this guide can be used to run the SMASH service.

## Running the node

We simply clone the node and use Nix to build it.
For example, if we want to use a specific version of the node, we can simply download it from the release page,
which is found here https://github.com/input-output-hk/cardano-node/releases.
Or you can clone the repository and simply use a specific tag from the release (for example, let us use a `1.14.2`):
```
git clone git@github.com:input-output-hk/cardano-node.git

git checkout 1.14.2 -b tag-1.14.2
```

### Testnet

In any case, after you have the version you require, you simply build the node using Nix:
```
nix-build -A scripts.shelley_testnet.node -o shelley-testnet-node
```

After that you can run the node by simply running:
```
./shelley-testnet-node
```

### Mainnet

In any case, after you have the version you require, you simply build the node using Nix:
```
nix-build -A scripts.mainnet.node -o mainnet-node-local
```

After that you can run the node by simply running:
```
./mainnet-node-local
```

## Building SMASH

You can download the version from https://github.com/input-output-hk/smash/releases.

After that, you can simply build the project using Stack, Cabal or Nix:
```
nix-build -o smash-local
```

And now we can setup the DB schema.

## DB setup using SMASH

Create a schema to your choosing and you can use SMASH to populate it.
What we need is a connection string.

For example, this is the content for `config/pgpass` which we use to connect to the database:
```
/var/run/postgresql:5432:smash:*:*
```

We simply create a schema, point the schema name and port number to the correct values and we store that
information, like above in a file somewhere. We will later use the location of that file to use it to
connect to that database and populate it.

Like this:
```
SMASHPGPASSFILE=config/pgpass ./scripts/postgresql-setup.sh --createdb
```

After this we need to run the migration required for SMASH to work. Again, we use the database config file:
```
SMASHPGPASSFILE=config/pgpass ./smash-local run-migrations --mdir ./schema
```

After that is completed, we should have a valid schema and should be able to run SMASH!

## Basic Auth and DB

You need to have the flag for disabling Basic auth not enabled (disabled).
After you run the migration scripts (see in this README examples), you can simply insert the user with the password in the DB:
```
INSERT INTO admin_user (username, password) VALUES ('ksaric', 'test');
```

That is it, you will now be able to run you SMASH server with user authentification from DB.
If you change your users/passwords, please restart the application since it takes a full restart for users to reload.

## Running SMASH

Finally, we have one thing left.
We first run the node, like mentioned above and in another terminal session/service we simply run SMASH.

We need to run it using appropriate parameters, since running it requires it to be in sync with the node.
This example is running it using the testnet and using the shelley genesis found when running the node.
The socket path is just pointing to a socket that will be used for communication with the node.
The example:
```
SMASHPGPASSFILE=config/pgpass ./smash-local run-app-with-db-sync --config config/testnet-config.yaml --genesis-file /nix/store/hih30xck46bw2l4mlz6b36dsdnd2cwh4-shelley-testnet-genesis.json --socket-path ../cardano-node/state-node-shelley_testnet/node.socket --schema-dir schema/
```

After this, the SMASH application should start syncing blocks and picking up pools.

## Checking if it works

For example, after seeing that a pool has be registered, you can try to get it's info by running it's hash (the example here is `93b13334b5edf623fd4c7a716f3cf47be5baf7fb3a431c16ee07aab8ff074873`):
```
curl -X GET -v http://localhost:3100/api/v1/metadata/93b13334b5edf623fd4c7a716f3cf47be5baf7fb3a431c16ee07aab8ff074873
```

You can test the blacklisting by sending a PATCH on the blacklist endpoint.
```
curl -X PATCH -v http://localhost:3100/api/v1/blacklist -H 'content-type: application/json' -d '{"poolHash": "93b13334b5edf623fd4c7a716f3cf47be5baf7fb3a431c16ee07aab8ff074873"}'
```

Or if you have Basic Auth enabled (replace with you username/pass you have in your DB):
```
curl -u ksaric:cirask -X PATCH -v http://localhost:3100/api/v1/blacklist -H 'content-type: application/json' -d '{"poolHash": "93b13334b5edf623fd4c7a716f3cf47be5baf7fb3a431c16ee07aab8ff074873"}'
```

