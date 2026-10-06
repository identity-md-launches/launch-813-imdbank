# Offline dependencies

Foundry builds need only Solidity 0.8.26 and the ordinary files in this repository. No submodules, FFI, filesystem cheatcodes, or environment variables are needed for the default tests.

* `lib/forge-std/src`: forge-std v1.9.7, downloaded from the tag archive at https://github.com/foundry-rs/forge-std/releases/tag/v1.9.7. Upstream MIT/Apache notices are included. Test infrastructure only.
* `lib/openzeppelin-contracts`: Math.sol, SafeCast.sol and Panic.sol from OpenZeppelin Contracts v5.2.0, https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.2.0; MIT license included. Full precision arithmetic; no Aave implementation code is copied.

Frontend dependency provenance is recorded in `web/` and `docs/FRONTEND.md`. Dependencies must stay vendored; a package registry or CDN is not part of the offline build.
