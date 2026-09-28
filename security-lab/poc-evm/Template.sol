// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Template for an EVM-level PoC. Deploy and call it only through
// scripts/run-poc.sh inside the poc-runner container, e.g.:
//   docker compose exec poc-runner scripts/run-poc.sh \
//     forge create poc-evm/Template.sol:PoC --broadcast
//
// Typical shape of a StateDB desync PoC: call a stateful precompile, then
// revert (directly, in try/catch or in a nested call), and compare balances
// before and after from the outside.
contract PoC {
    function run() external payable {
        // attack steps go here
    }
}
