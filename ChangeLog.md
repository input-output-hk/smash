# Changelog for smash

## 1.0.0

### Story

[CAD-1397] - ITN Ticker protection for mainnet and SMASH
[CAD-1399] - Change wording in documentation and codebase to delist/list
[CAD-1409] - Will not retry fetching metadata if hash mismatches or URL is not available
[CAD-1428] - Change the primary database key to be "poolid", not ticker name
[CAD-1446] - Support delayed registration of metadata
[CAD-1449] - Exponential back-off to pull Stake Pools metadata in case there’s a timeout or an HTTP error returned by the pool metadata server
[CAD-1456] - Implement blacklisting for pool ids
[CAD-1462] - Clarify insert ticker command name and report error if ticker already exists

### Bug

[CAD-1390] - Fix Nix issue


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

