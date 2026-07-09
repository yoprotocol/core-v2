// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { YoMayanAdapter } from "../src/adapters/mayan/YoMayanAdapter.sol";
import { IMayanForwarder } from "../src/interfaces/external/IMayanForwarder.sol";
import { IYoBridgeRouteRegistry } from "../src/interfaces/IYoBridgeRouteRegistry.sol";
import { IYoRegistry } from "../src/interfaces/IYoRegistry.sol";
import { IYoSwapOracle } from "../src/interfaces/IYoSwapOracle.sol";
import { IYoSwapPairRegistry } from "../src/interfaces/IYoSwapPairRegistry.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys the immutable {YoMayanAdapter} bound to the Mayan Forwarder, the Swift protocol,
///         and the shared {YoBridgeRouteRegistry}. Swift `createOrderWithToken` only; the adapter
///         decodes the forwarded order and gates its destination + refund owner on-chain.
///
///         Post-deploy operational steps (multisig, per vault):
///           - `routeRegistry.setRoute(vault, adapter, tokenIn, wormholeChainId, destAddr, true)`.
///           - `approvalRegistry.setApproval(vault, tokenIn, adapter, cap)` then
///             `vault.approveToken(tokenIn, adapter, cap)`.
///           - Grant the operator the `forwardERC20` / `swapAndForwardERC20` selectors on the
///             vault's authority.
///
///         Required env vars:
///           - YO_REGISTRY:               live YoRegistry proxy (adapter `rescue` auth).
///           - YO_BRIDGE_ROUTE_REGISTRY:  deployed {YoBridgeRouteRegistry} on this chain.
///           - YO_SWAP_ORACLE:            deployed YoChainlinkOracle (floors the swap leg).
///           - YO_SWAP_PAIR_REGISTRY:     deployed YoSwapPairRegistry (gates the swap pair).
///         Optional env vars:
///           - MAYAN_FORWARDER, MAYAN_SWIFT: override the chain-pinned addresses.
///           - ETH_FROM, MNEMONIC:           broadcaster key (see {BaseScript}).
contract Deploy_MayanAdapter is BaseScript {
    error ForwarderNotDeployed(uint256 chainId, address forwarder);
    error SwiftNotDeployed(uint256 chainId, address swift);

    function run() public broadcast returns (YoMayanAdapter adapter) {
        IYoRegistry yoRegistry = IYoRegistry(getYoRegistry());
        IYoBridgeRouteRegistry routeRegistry = IYoBridgeRouteRegistry(vm.envAddress("YO_BRIDGE_ROUTE_REGISTRY"));

        address forwarder = getMayanForwarder();
        if (forwarder.code.length == 0) {
            revert ForwarderNotDeployed(chainId, forwarder);
        }
        address swift = getMayanSwift();
        if (swift.code.length == 0) {
            revert SwiftNotDeployed(chainId, swift);
        }

        adapter = new YoMayanAdapter{ salt: SALT }(
            YoMayanAdapter.InitParams({
                forwarder: IMayanForwarder(forwarder),
                swiftProtocol: swift,
                routeRegistry: routeRegistry,
                oracle: IYoSwapOracle(vm.envAddress("YO_SWAP_ORACLE")),
                pairRegistry: IYoSwapPairRegistry(vm.envAddress("YO_SWAP_PAIR_REGISTRY")),
                maxSwapSlippageBps: getMaxSlippageBps(),
                maxBridgeSlippageBps: getMaxBridgeSlippageBps(),
                maxOrderFeeBps: getMaxOrderFeeBps(),
                yoRegistry: yoRegistry
            })
        );

        console2.log("=== YO Mayan Adapter Deployed ===");
        console2.log("Chain ID:               ", chainId);
        console2.log("Version:                ", YO_VERSION);
        console2.log("Salt:                   ");
        console2.logBytes32(SALT);
        console2.log("");
        console2.log("YoMayanAdapter:         ", address(adapter));
        console2.log("Mayan Forwarder:        ", forwarder);
        console2.log("Mayan Swift:            ", swift);
        console2.log("YoBridgeRouteRegistry:  ", address(routeRegistry));
        console2.log("YoRegistry (existing):  ", address(yoRegistry));
    }
}
