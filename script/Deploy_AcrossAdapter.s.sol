// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { YoAcrossAdapter } from "../src/adapters/across/YoAcrossAdapter.sol";
import { IAcrossSpokePool } from "../src/interfaces/external/IAcrossSpokePool.sol";
import { IYoBridgeRouteRegistry } from "../src/interfaces/IYoBridgeRouteRegistry.sol";
import { IYoRegistry } from "../src/interfaces/IYoRegistry.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys the immutable {YoAcrossAdapter} bound to the chain's Across `SpokePool` and the
///         shared {YoBridgeRouteRegistry}. ERC-20 input only; destinations are gated by the route
///         registry.
///
///         Post-deploy operational steps (multisig, per vault):
///           - `routeRegistry.setRoute(vault, adapter, inputToken, destChainId, recipient, true)`.
///           - `approvalRegistry.setApproval(vault, inputToken, adapter, cap)` then
///             `vault.approveToken(inputToken, adapter, cap)`.
///           - Grant the operator the `deposit` selector on the vault's authority.
///
///         Required env vars:
///           - YO_REGISTRY:               live YoRegistry proxy (adapter `rescue` auth).
///           - YO_BRIDGE_ROUTE_REGISTRY:  deployed {YoBridgeRouteRegistry} on this chain.
///         Optional env vars:
///           - ACROSS_SPOKE_POOL:         override the chain-pinned SpokePool address.
///           - ETH_FROM, MNEMONIC:        broadcaster key (see {BaseScript}).
contract Deploy_AcrossAdapter is BaseScript {
    error SpokePoolNotDeployed(uint256 chainId, address spokePool);

    function run() public broadcast returns (YoAcrossAdapter adapter) {
        IYoRegistry yoRegistry = IYoRegistry(getYoRegistry());
        IYoBridgeRouteRegistry routeRegistry = IYoBridgeRouteRegistry(vm.envAddress("YO_BRIDGE_ROUTE_REGISTRY"));

        address spokePool = getAcrossSpokePool();
        if (spokePool.code.length == 0) {
            revert SpokePoolNotDeployed(chainId, spokePool);
        }

        adapter = new YoAcrossAdapter{ salt: SALT }(IAcrossSpokePool(spokePool), routeRegistry, yoRegistry);

        console2.log("=== YO Across Adapter Deployed ===");
        console2.log("Chain ID:               ", chainId);
        console2.log("Version:                ", YO_VERSION);
        console2.log("Salt:                   ");
        console2.logBytes32(SALT);
        console2.log("");
        console2.log("YoAcrossAdapter:        ", address(adapter));
        console2.log("Across SpokePool:       ", spokePool);
        console2.log("YoBridgeRouteRegistry:  ", address(routeRegistry));
        console2.log("YoRegistry (existing):  ", address(yoRegistry));
    }
}
