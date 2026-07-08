// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoCctpAdapter } from "../src/adapters/cctp/YoCctpAdapter.sol";
import { ITokenMessengerV2 } from "../src/interfaces/external/ITokenMessengerV2.sol";
import { IYoBridgeRouteRegistry } from "../src/interfaces/IYoBridgeRouteRegistry.sol";
import { IYoRegistry } from "../src/interfaces/IYoRegistry.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys the immutable {YoCctpAdapter} bound to the chain's CCTP V2 `TokenMessengerV2`,
///         native USDC, and the shared {YoBridgeRouteRegistry}. USDC-only by construction;
///         mint destinations are gated by the route registry (keyed on Circle domain ids).
///
///         Post-deploy operational steps (multisig, per vault):
///           - `routeRegistry.setRoute(vault, adapter, usdc, destDomain, mintRecipient, true)`.
///           - `approvalRegistry.setApproval(vault, usdc, adapter, cap)` then
///             `vault.approveToken(usdc, adapter, cap)`.
///           - Grant the operator the `depositForBurn` selector on the vault's authority.
///
///         Required env vars:
///           - YO_REGISTRY:               live YoRegistry proxy (adapter `rescue` auth).
///           - YO_BRIDGE_ROUTE_REGISTRY:  deployed {YoBridgeRouteRegistry} on this chain.
///         Optional env vars:
///           - CCTP_TOKEN_MESSENGER, USDC: override the chain-pinned addresses.
///           - ETH_FROM, MNEMONIC:         broadcaster key (see {BaseScript}).
contract Deploy_CctpAdapter is BaseScript {
    error TokenMessengerNotDeployed(uint256 chainId, address tokenMessenger);

    function run() public broadcast returns (YoCctpAdapter adapter) {
        IYoRegistry yoRegistry = IYoRegistry(getYoRegistry());
        IYoBridgeRouteRegistry routeRegistry = IYoBridgeRouteRegistry(vm.envAddress("YO_BRIDGE_ROUTE_REGISTRY"));

        address tokenMessenger = getCctpTokenMessenger();
        if (tokenMessenger.code.length == 0) {
            revert TokenMessengerNotDeployed(chainId, tokenMessenger);
        }
        IERC20 usdc = IERC20(getUSDC());

        adapter = new YoCctpAdapter{ salt: SALT }(
            ITokenMessengerV2(tokenMessenger), usdc, routeRegistry, getMaxFeeBps(), yoRegistry
        );

        console2.log("=== YO CCTP Adapter Deployed ===");
        console2.log("Chain ID:               ", chainId);
        console2.log("Version:                ", YO_VERSION);
        console2.log("Salt:                   ");
        console2.logBytes32(SALT);
        console2.log("");
        console2.log("YoCctpAdapter:          ", address(adapter));
        console2.log("CCTP TokenMessengerV2:  ", tokenMessenger);
        console2.log("USDC:                   ", address(usdc));
        console2.log("YoBridgeRouteRegistry:  ", address(routeRegistry));
        console2.log("YoRegistry (existing):  ", address(yoRegistry));
    }
}
