// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { YoPoolRegistry } from "../src/registries/YoPoolRegistry.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys the shared {YoPoolRegistry}, owned by the YO multisig. This is the per-chain
///         registry of record for the pool whitelist (roster, governance scalars, epoch); it does
///         not gate execution, so it has no ordering dependency on the adapters.
///
///         Post-deploy operational steps (multisig, per vault + pool):
///           - `poolRegistry.setPool(vault, offchainId, config)` as the LAST call of each pool
///             onboarding batch (see {Configure_Pool}).
///           - Ownership transfer to the timelock is a follow-up operational step.
///
///         Optional env vars:
///           - YO_OWNER:           registry owner (defaults via {BaseScript-getYoOwner}).
///           - YO_GUARDIAN:        kill-switch guardian; defaults to `address(0)` (disabled) until
///                                 set via `setGuardian`.
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}).
contract Deploy_PoolRegistry is BaseScript {
    function run() public broadcast returns (YoPoolRegistry poolRegistry) {
        address owner = getYoOwner();
        address guardian = vm.envOr({ name: "YO_GUARDIAN", defaultValue: address(0) });

        poolRegistry = new YoPoolRegistry{ salt: SALT }(owner, guardian);

        console2.log("=== YO Pool Registry Deployed ===");
        console2.log("Chain ID:               ", chainId);
        console2.log("Version:                ", YO_VERSION);
        console2.log("Salt:                   ");
        console2.logBytes32(SALT);
        console2.log("");
        console2.log("YoPoolRegistry:         ", address(poolRegistry));
        console2.log("Owner:                  ", owner);
        console2.log("Guardian:               ", guardian);
    }
}
