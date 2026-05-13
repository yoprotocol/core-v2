// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys OpenZeppelin's {TimelockController} deterministically via CREATE2.
/// @dev    Required env vars:
///         - TIMELOCK_MIN_DELAY: minimum delay (in seconds) between scheduling and execution.
///         - TIMELOCK_PROPOSERS: comma-separated list of addresses with PROPOSER_ROLE
///                               (also receive CANCELLER_ROLE in OZ 5.x).
///         - TIMELOCK_EXECUTORS: comma-separated list of addresses with EXECUTOR_ROLE.
///                               Use the zero address (0x0000...0000) to allow anyone to execute.
///
///         Optional env vars:
///         - TIMELOCK_ADMIN: address granted DEFAULT_ADMIN_ROLE for initial setup.
///                           Defaults to address(0) — strongly recommended so the timelock
///                           self-administers (any role change must go through the timelock).
///         - SALT: bytes32 CREATE2 salt. Defaults to ZERO_SALT.
contract DeployTimelock is BaseScript {
    function run() public broadcast returns (TimelockController timelock) {
        uint256 minDelay = vm.envUint("TIMELOCK_MIN_DELAY");
        address[] memory proposers = vm.envAddress("TIMELOCK_PROPOSERS", ",");
        address[] memory executors = vm.envAddress("TIMELOCK_EXECUTORS", ",");
        address admin = vm.envOr({ name: "TIMELOCK_ADMIN", defaultValue: address(0) });
        bytes32 salt = vm.envOr({ name: "SALT", defaultValue: ZERO_SALT });

        timelock = new TimelockController{ salt: salt }(minDelay, proposers, executors, admin);
    }
}
