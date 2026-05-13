// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { IMorpho } from "../src/interfaces/IMorpho.sol";
import { RoadrunnerWithdrawer } from "../src/adapters/morpho/MorphoAdapter.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys {RoadrunnerWithdrawer} deterministically via CREATE2.
/// @dev    Foundry routes `new C{salt: s}(...)` through the canonical CREATE2 deployer
///         (0x4e59b44847b379578588920cA78FbF26c0B4956C), so the deployed address depends
///         only on the bytecode and salt — not on the broadcaster EOA.
///
///         Optional env vars:
///         - SALT: bytes32 CREATE2 salt. Defaults to ZERO_SALT.
contract Deploy is BaseScript {
    function run() public broadcast returns (RoadrunnerWithdrawer adapter) {
        IMorpho morpho = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
        address owner = 0x67b6F699F1c8040414032a3C2C88a54db144FCd2;
        bytes32 salt = vm.envOr({ name: "SALT", defaultValue: ZERO_SALT });
        adapter = new RoadrunnerWithdrawer{ salt: salt }(owner, morpho);
    }
}
