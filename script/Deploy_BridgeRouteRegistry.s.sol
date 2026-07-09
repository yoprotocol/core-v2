// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { YoBridgeRouteRegistry } from "../src/registries/YoBridgeRouteRegistry.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys the shared {YoBridgeRouteRegistry}, owned by the YO multisig. Every bridge
///         adapter (`YoAcrossAdapter`, `YoCcipAdapter`, `YoCctpAdapter`) consults this registry for
///         the on-chain destination floor, so it must be deployed before the adapters.
///
///         Post-deploy operational steps (multisig, per vault + bridge):
///           - `routeRegistry.setRoute(vault, adapter, token, destinationId, recipient, true)` for
///             each allowed cross-chain route.
///           - Ownership transfer to the timelock is a follow-up operational step.
///
///         Optional env vars:
///           - YO_OWNER:           registry owner (defaults via {BaseScript-getYoOwner}).
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}).
contract Deploy_BridgeRouteRegistry is BaseScript {
    function run() public broadcast returns (YoBridgeRouteRegistry routeRegistry) {
        address owner = getYoOwner();

        routeRegistry = new YoBridgeRouteRegistry{ salt: SALT }(owner);

        console2.log("=== YO Bridge Route Registry Deployed ===");
        console2.log("Chain ID:               ", chainId);
        console2.log("Version:                ", YO_VERSION);
        console2.log("Salt:                   ");
        console2.logBytes32(SALT);
        console2.log("");
        console2.log("YoBridgeRouteRegistry:  ", address(routeRegistry));
        console2.log("Owner:                  ", owner);
    }
}
