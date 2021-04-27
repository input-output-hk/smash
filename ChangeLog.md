# Changelog for smash


## 1.5.0

### Story

- [CAD-2547] - Add Prometheus metrics for slot_no
- [CAD-2581] - Use the general db-sync plugins system to implement SMASH
- [CAD-2651] - Fix/improve caching
- [CAD-2671] - Modify cardano-sync to enable reusing from SMASH
- [CAD-2724] - CLI option to switch to existing SMASH server filtering
- [CAD-2810] - Add CLI for checking of pool metadata hash
- [CAD-2811] - Fix error handling to show last 10 results by default

### Bug

- [CAD-2832] - Smash syncing from scratch every restart


## 1.4.0

### Story

- [CAD-1357] - Remove any traces of cardano-db-sync
- [CAD-2180] - Documentation improvements
- [CAD-2184] - Fix Swagger documentation to be consistent, add more info
- [CAD-2449] - Add API endpoint for checking valid pool id
- [CAD-2450] - Bump up to Mary (Native tokens) support

### Bug

- [CAD-2408] - Create directory for --state-dir automatically if it does not exist
- [CAD-2416] - Database connection inconsistency
- [CAD-2476] - SMASH not returning active pools that were previously retired


## 1.3.0

### Story

- [CAD-2169] - Expose API types in a separate package
- [CAD-2177] - smash should work also with pool_ids in Bech32 format
- [CAD-2182] - Pool insertion and ticker insertion should be added into API
- [CAD-2183] - Add/remove admin user via CLI
- [CAD-2323] - Bump up to Allegra Hard Fork

### Bug

- [CAD-2176] - errors endpoint doesn't validate poolId properly
- [CAD-2178] - The retryCount from the /errors endpoint is not correctly incremented
- [CAD-2179] - pool_id delist endpoint is returning 200 for any string (not only for valid pool_ids)
- [CAD-2181] - All queries that don't return anything should return 404


## 1.2.0

### Story

- [CAD-1358] - Return the caching headers for the HTTP server to work with that
- [CAD-1823] - Stake pools with issues list
- [CAD-1824] - List of delisted Stake pools
- [CAD-1838] - Add whitelisting (listing) to return delisted
- [CAD-1926] - Retired pools should be ignored
- [CAD-2061] - Logs improvement, add information to why an error occured
- [CAD-2074] - Health check endpoint
- [CAD-2085] - Create migration scripts for SMASH
- [CAD-2088] - Resolve paths relative to the config file, not the executable
- [CAD-2093] - Use qualified module names


## 1.1.0

### Story

- [CAD-1744] - Easily query reason for pool metadata lookup failure

### Bug

- [CAD-1791] - smash on shelley-qa is failing when decoding address
- [CAD-1753] - TLS version 1.3 not working correctly


## 1.0.1

### Bug

- [CAD-1471] - Query pool id along with hash when looking for pool info


## 1.0.0

### Story

- [CAD-1397] - ITN Ticker protection for mainnet and SMASH
- [CAD-1399] - Change wording in documentation and codebase to delist/list
- [CAD-1409] - Will not retry fetching metadata if hash mismatches or URL is not available
- [CAD-1428] - Change the primary database key to be "poolid", not ticker name
- [CAD-1446] - Support delayed registration of metadata
- [CAD-1449] - Exponential back-off to pull Stake Pools metadata in case there’s a timeout or an HTTP error returned by the pool metadata server
- [CAD-1456] - Implement blacklisting for pool ids
- [CAD-1462] - Clarify insert ticker command name and report error if ticker already exists

### Bug

- [CAD-1390] - Fix Nix issue


## 0.1.0

### Story

- [CAD-762] - Initial API design
- [CAD-770] - Add a simple in-memory database
- [CAD-778] - Add block syncing mechanism
- [CAD-779] - Add a database backend
- [CAD-1266] - Adapt cardano-db-sync for SMASH
- [CAD-1330] - Add http client for fetching JSON metadata
- [CAD-1348] - Add block insertion so we don't sync from scratch
- [CAD-1353] - Add JSON size check for offline metadata
- [CAD-1361] - Servers return `200 OK` when metadata isn't found
- [CAD-1354] - Add deny list functionality
- [CAD-1355] - Add a flag for switching Basic Auth off/onn
- [CAD-1360] - Add documentation for third party clients
- [CAD-1371] - Integrate SMASH against HFC

### Bug

- [CAD-1361] - Servers return `200 OK` when metadata isn't found

