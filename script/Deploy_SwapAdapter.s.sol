// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { IYoRegistry } from "../src/interfaces/IYoRegistry.sol";
import { IYoSwapOracle } from "../src/interfaces/IYoSwapOracle.sol";
import { IYoSwapPairRegistry } from "../src/interfaces/IYoSwapPairRegistry.sol";

import { YoSwapAdapter } from "../src/adapters/swap/YoSwapAdapter.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys one immutable {YoSwapAdapter} bound to a chosen aggregator (Enso, Curve, or any
///         approve-based synchronous aggregator), reusing the swap oracle and pair registry already
///         deployed by {Deploy_V3_Stack}. Run once per target aggregator.
///
///         The adapter is calldata-agnostic: the operator supplies the route in
///         `aggregatorCalldata`, correctness is enforced by the post-swap balance-delta and the
///         oracle floor (`_maxSlippageBps`). The route's `to` must equal the bound aggregator and
///         its receiver must be the adapter or the vault, or the swap reverts on output checks.
///
///         CREATE2 note: every adapter shares the versioned `SALT`, but differing constructor args
///         (aggregator + slippage) yield distinct initcode and therefore distinct addresses — no
///         collision between, e.g., the Enso and Curve adapters.
///
///         Required env vars:
///           - YO_REGISTRY:           live YoRegistry proxy on the target chain (adapter `rescue` auth).
///           - YO_SWAP_ORACLE:        deployed YoChainlinkOracle (from Deploy_V3_Stack) on this chain.
///           - YO_SWAP_PAIR_REGISTRY: deployed YoSwapPairRegistry (from Deploy_V3_Stack) on this chain.
///           - Aggregator selection (one of):
///               · AGGREGATOR:         a known name — "enso" or "curve" — resolved via {BaseScript}
///                                     getters (chain-aware where applicable).
///               · AGGREGATOR_ADDRESS: an explicit router address for any other aggregator. Takes
///                                     precedence over AGGREGATOR when set.
///
///         Optional env vars:
///           - MAX_SLIPPAGE_BPS:   oracle-floor slippage in bps. Defaults to {getMaxSlippageBps}.
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}).
contract Deploy_SwapAdapter is BaseScript {
    error UnknownAggregator(string name);
    error AggregatorNotDeployed(uint256 chainId, address aggregator);

    function run() public broadcast returns (YoSwapAdapter swapAdapter) {
        IYoRegistry yoRegistry = IYoRegistry(getYoRegistry());

        address aggregator = _resolveAggregator();
        if (aggregator.code.length == 0) {
            revert AggregatorNotDeployed(chainId, aggregator);
        }

        uint256 maxSlippageBps = vm.envOr({ name: "MAX_SLIPPAGE_BPS", defaultValue: getMaxSlippageBps() });
        IYoSwapOracle oracle = IYoSwapOracle(vm.envAddress("YO_SWAP_ORACLE"));
        IYoSwapPairRegistry registry = IYoSwapPairRegistry(vm.envAddress("YO_SWAP_PAIR_REGISTRY"));

        swapAdapter = new YoSwapAdapter{ salt: SALT }({
            _aggregator: aggregator,
            _oracle: oracle,
            _registry: registry,
            _maxSlippageBps: maxSlippageBps,
            _yoRegistry: yoRegistry
        });

        _log(swapAdapter, aggregator, maxSlippageBps, address(oracle), address(registry), address(yoRegistry));
    }

    /// @dev Resolve the aggregator: prefer an explicit `AGGREGATOR_ADDRESS`; otherwise map the
    ///      `AGGREGATOR` name to its chain-aware {BaseScript} getter.
    function _resolveAggregator() internal view returns (address) {
        address explicitAddress = vm.envOr({ name: "AGGREGATOR_ADDRESS", defaultValue: address(0) });
        if (explicitAddress != address(0)) {
            return explicitAddress;
        }

        string memory name = vm.envString("AGGREGATOR");
        bytes32 nameHash = keccak256(bytes(name));
        if (nameHash == keccak256(bytes("enso"))) {
            return getEnsoRouter();
        }
        if (nameHash == keccak256(bytes("curve"))) {
            return getCurveRouter();
        }
        revert UnknownAggregator(name);
    }

    function _log(
        YoSwapAdapter swapAdapter,
        address aggregator,
        uint256 maxSlippageBps,
        address oracle,
        address registry,
        address yoRegistry
    )
        internal
        view
    {
        console2.log("=== YO Swap Adapter Deployed ===");
        console2.log("Chain ID:             ", chainId);
        console2.log("Version:              ", YO_VERSION);
        console2.log("Salt:                 ");
        console2.logBytes32(SALT);
        console2.log("");
        console2.log("YoSwapAdapter:        ", address(swapAdapter));
        console2.log("Aggregator:           ", aggregator);
        console2.log("Max slippage (bps):   ", maxSlippageBps);
        console2.log("YoChainlinkOracle:    ", oracle);
        console2.log("YoSwapPairRegistry:   ", registry);
        console2.log("YoRegistry (existing):", yoRegistry);
    }
}
