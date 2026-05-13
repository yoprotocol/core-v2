// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { YoUSDTAdapter } from "../src/adapters/yousdt/YoUSDTAdapter.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys {YoUSDTAdapter} deterministically via CREATE2.
/// @dev    No constructor args — USDT and VAULT are compile-time constants, so the
///         deployed address depends only on the bytecode and salt.
///
///         Optional env vars:
///         - SALT: bytes32 CREATE2 salt. Defaults to ZERO_SALT.
contract DeployYoUSDT is BaseScript {
    function run() public broadcast returns (YoUSDTAdapter adapter) {
        bytes32 salt = vm.envOr({ name: "SALT", defaultValue: ZERO_SALT });
        adapter = new YoUSDTAdapter{ salt: salt }();
    }
}
