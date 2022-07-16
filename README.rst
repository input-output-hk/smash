.. raw:: html

   <p align="center">
     <a href="https://github.com/input-output-hk/smash/releases"><img src="https://img.shields.io/github/release-pre/input-output-hk/smash.svg?style=for-the-badge" /></a>
     <a href="https://coveralls.io/github/input-output-hk/smash?branch=master"><img src="https://coveralls.io/repos/github/input-output-hk/smash/badge.svg?branch=master" /></a>
   </p>
   
Deprecated Note:

⚠️ This project is deprecated, and only supports up to cardano-node 1.30.1, for newer versions of cardano-node use the SMASH server in https://github.com/input-output-hk/cardano-db-sync. Do not use anymore, it is here for historical purpose.

*************************
``smash`` Overview
*************************

This repository contains the source code for the Cardano Stakepool Metadata Aggregation Server (SMASH).
The purpose of SMASH is to aggregate common metadata about stakepools that are registered
on the Cardano blockchain, including the name of the stakepool, its "ticker" name etc.
This metadata can be curated and provided as a service to delegators, stake pool operators,
exchanges etc., enabling independent validation and/or disambiguation of stakepool "ticker" names, for example.

