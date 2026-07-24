// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoAcrossAdapter } from "../src/adapters/across/YoAcrossAdapter.sol";
import { YoCcipAdapter } from "../src/adapters/ccip/YoCcipAdapter.sol";
import { YoCctpAdapter } from "../src/adapters/cctp/YoCctpAdapter.sol";
import { YoMayanAdapter } from "../src/adapters/mayan/YoMayanAdapter.sol";

import { IAcrossSpokePool } from "../src/interfaces/external/IAcrossSpokePool.sol";
import { ICcipRouterClient } from "../src/interfaces/external/ICcipRouterClient.sol";
import { IMayanForwarder } from "../src/interfaces/external/IMayanForwarder.sol";
import { ITokenMessengerV2 } from "../src/interfaces/external/ITokenMessengerV2.sol";
import { IYoBridgeRouteRegistry } from "../src/interfaces/IYoBridgeRouteRegistry.sol";
import { IYoRegistry } from "../src/interfaces/IYoRegistry.sol";
import { IYoSwapOracle } from "../src/interfaces/IYoSwapOracle.sol";
import { IYoSwapPairRegistry } from "../src/interfaces/IYoSwapPairRegistry.sol";

import { YoBridgeRouteRegistry } from "../src/registries/YoBridgeRouteRegistry.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys the full YO bridge stack in one shot: the shared {YoBridgeRouteRegistry} plus up
///         to four immutable bridge adapters (Across / CCIP / CCTP / Mayan). All contracts use
///         deterministic CREATE2 with the version-scoped salt from {BaseScript}. The registry is
///         deployed first and wired into every adapter directly, so — unlike the per-adapter scripts
///         — no `YO_BRIDGE_ROUTE_REGISTRY` env round-trip is needed.
///
///         Chain-aware, auto-skipping: each adapter is deployed only when its dependencies resolve on
///         the target chain (chain-pinned bridge address present + on-chain code). An adapter whose
///         bridge is not available on this chain is skipped with a log line rather than reverting, so
///         the same command works across every network. Skips:
///           - Across: no chain-pinned `SpokePool` (or `ACROSS_SPOKE_POOL`) / no code at the address.
///           - CCIP:   no chain-pinned `Router` (or `CCIP_ROUTER`) / no code at the address.
///           - CCTP:   no code at the (deterministic) `TokenMessengerV2`, or USDC not resolvable.
///           - Mayan:  no code at the (deterministic) Forwarder / Swift contracts.
///
///         Mayan additionally depends on the V3 swap stack: when it deploys it reads `YO_SWAP_ORACLE`
///         and `YO_SWAP_PAIR_REGISTRY` (from a prior {Deploy_V3_Stack} run) and reverts if unset.
///
///         Post-deploy operational steps (multisig, per vault + bridge):
///           - `routeRegistry.setRoute(vault, adapter, token, destinationId, recipient, true)`.
///           - `approvalRegistry.setApproval(vault, token, adapter, cap)` then
///             `vault.approveToken(token, adapter, cap)`.
///           - Grant the operator the adapter's bridge selector on the vault's authority.
///           - Registry ownership transfer to the timelock is a follow-up operational step.
///
///         Required env vars:
///           - YO_REGISTRY:            live YoRegistry proxy (adapter `rescue` auth).
///           - YO_SWAP_ORACLE:         deployed YoChainlinkOracle — required only if Mayan deploys.
///           - YO_SWAP_PAIR_REGISTRY:  deployed YoSwapPairRegistry — required only if Mayan deploys.
///         Optional env vars:
///           - YO_OWNER:               registry owner (defaults via {BaseScript-getYoOwner}).
///           - ACROSS_SPOKE_POOL, CCIP_ROUTER, CCTP_TOKEN_MESSENGER, USDC, MAYAN_FORWARDER,
///             MAYAN_SWIFT: override the chain-pinned bridge addresses.
///           - ETH_FROM, MNEMONIC:     broadcaster key (see {BaseScript}).
contract Deploy_Bridge_Stack is BaseScript {
    struct Deployments {
        YoBridgeRouteRegistry routeRegistry;
        YoAcrossAdapter acrossAdapter; // address(0) when Across is unavailable on this chain
        YoCcipAdapter ccipAdapter; // address(0) when CCIP is unavailable on this chain
        YoCctpAdapter cctpAdapter; // address(0) when CCTP is unavailable on this chain
        YoMayanAdapter mayanAdapter; // address(0) when Mayan is unavailable on this chain
    }

    function run() public broadcast returns (Deployments memory d) {
        address owner = getYoOwner();
        IYoRegistry yoRegistry = IYoRegistry(getYoRegistry());

        d.routeRegistry = new YoBridgeRouteRegistry{ salt: SALT }(owner);
        IYoBridgeRouteRegistry routeRegistry = IYoBridgeRouteRegistry(address(d.routeRegistry));

        // Across — deployed only when a SpokePool with code resolves on this chain.
        address spokePool = _withCode(getAcrossSpokePoolOrZero());
        if (spokePool != address(0)) {
            d.acrossAdapter = new YoAcrossAdapter{ salt: SALT }(
                IAcrossSpokePool(spokePool), routeRegistry, getMaxSlippageBps(), yoRegistry
            );
        }

        // CCIP — deployed only when a Router with code resolves on this chain.
        address ccipRouter = _withCode(getCcipRouterOrZero());
        if (ccipRouter != address(0)) {
            d.ccipAdapter = new YoCcipAdapter{ salt: SALT }(ICcipRouterClient(ccipRouter), routeRegistry, yoRegistry);
        }

        // CCTP — deployed only when both the TokenMessengerV2 and USDC resolve with code on this chain.
        address tokenMessenger = _withCode(getCctpTokenMessenger());
        address usdc = _withCode(getUSDCOrZero());
        if (tokenMessenger != address(0) && usdc != address(0)) {
            d.cctpAdapter = new YoCctpAdapter{ salt: SALT }(
                ITokenMessengerV2(tokenMessenger), IERC20(usdc), routeRegistry, getMaxFeeBps(), yoRegistry
            );
        }

        // Mayan — deployed only when both the Forwarder and Swift contracts have code on this chain.
        // Requires the V3 swap oracle + pair registry (reverts if their env vars are unset).
        address forwarder = _withCode(getMayanForwarder());
        address swift = _withCode(getMayanSwift());
        if (forwarder != address(0) && swift != address(0)) {
            d.mayanAdapter = new YoMayanAdapter{ salt: SALT }(
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
        }

        _log(d, owner, address(yoRegistry));
    }

    /// @dev Passes through a resolved bridge address only if it has on-chain code, else `address(0)`.
    ///      Lets deterministic-address bridges (CCTP / Mayan) be skipped on chains where they are not
    ///      yet live, and guards the chain-pinned addresses against a stale/wrong entry. Callers pass
    ///      the non-reverting `...OrZero` getters, so an unlisted chain already yields `address(0)`.
    function _withCode(address target) internal view returns (address) {
        return target.code.length == 0 ? address(0) : target;
    }

    function _log(Deployments memory d, address owner, address yoRegistry) internal view {
        console2.log("=== YO Bridge Stack Deployed ===");
        console2.log("Chain ID:               ", chainId);
        console2.log("Version:                ", YO_VERSION);
        console2.log("Salt:                   ");
        console2.logBytes32(SALT);
        console2.log("Owner:                  ", owner);
        console2.log("YoRegistry (existing):  ", yoRegistry);
        console2.log("");
        console2.log("YoBridgeRouteRegistry:  ", address(d.routeRegistry));
        console2.log("");
        _logAdapter("YoAcrossAdapter:        ", address(d.acrossAdapter));
        _logAdapter("YoCcipAdapter:          ", address(d.ccipAdapter));
        _logAdapter("YoCctpAdapter:          ", address(d.cctpAdapter));
        _logAdapter("YoMayanAdapter:         ", address(d.mayanAdapter));
    }

    function _logAdapter(string memory label, address adapter) internal pure {
        if (adapter == address(0)) {
            console2.log(string.concat(label, " (skipped - unavailable on this chain)"));
        } else {
            console2.log(label, adapter);
        }
    }
}
