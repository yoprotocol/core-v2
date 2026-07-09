// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { YoCcipAdapter } from "../src/adapters/ccip/YoCcipAdapter.sol";
import { ICcipRouterClient } from "../src/interfaces/external/ICcipRouterClient.sol";
import { IYoBridgeRouteRegistry } from "../src/interfaces/IYoBridgeRouteRegistry.sol";
import { IYoRegistry } from "../src/interfaces/IYoRegistry.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys the immutable {YoCcipAdapter} bound to the chain's CCIP `Router` and the shared
///         {YoBridgeRouteRegistry}. Token transfers only (empty message payload); destinations are
///         gated by the route registry (keyed on CCIP chain selectors).
///
///         Post-deploy operational steps (multisig, per vault):
///           - `routeRegistry.setRoute(vault, adapter, token, destChainSelector, recipient, true)`.
///           - `approvalRegistry.setApproval(vault, token, adapter, cap)` then
///             `vault.approveToken(token, adapter, cap)`; same for the fee token if paying in LINK.
///           - Grant the operator the `send` selector on the vault's authority.
///
///         Required env vars:
///           - YO_REGISTRY:               live YoRegistry proxy (adapter `rescue` auth).
///           - YO_BRIDGE_ROUTE_REGISTRY:  deployed {YoBridgeRouteRegistry} on this chain.
///         Optional env vars:
///           - CCIP_ROUTER:               override the chain-pinned Router address.
///           - ETH_FROM, MNEMONIC:        broadcaster key (see {BaseScript}).
contract Deploy_CcipAdapter is BaseScript {
    error RouterNotDeployed(uint256 chainId, address router);

    function run() public broadcast returns (YoCcipAdapter adapter) {
        IYoRegistry yoRegistry = IYoRegistry(getYoRegistry());
        IYoBridgeRouteRegistry routeRegistry = IYoBridgeRouteRegistry(vm.envAddress("YO_BRIDGE_ROUTE_REGISTRY"));

        address router = getCcipRouter();
        if (router.code.length == 0) {
            revert RouterNotDeployed(chainId, router);
        }

        adapter = new YoCcipAdapter{ salt: SALT }(ICcipRouterClient(router), routeRegistry, yoRegistry);

        console2.log("=== YO CCIP Adapter Deployed ===");
        console2.log("Chain ID:               ", chainId);
        console2.log("Version:                ", YO_VERSION);
        console2.log("Salt:                   ");
        console2.logBytes32(SALT);
        console2.log("");
        console2.log("YoCcipAdapter:          ", address(adapter));
        console2.log("CCIP Router:            ", router);
        console2.log("YoBridgeRouteRegistry:  ", address(routeRegistry));
        console2.log("YoRegistry (existing):  ", address(yoRegistry));
    }
}
