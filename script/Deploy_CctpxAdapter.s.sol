// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoCctpxAdapter } from "../src/adapters/cctpx/YoCctpxAdapter.sol";
import { ICrossChainTokenService } from "../src/interfaces/external/ICrossChainTokenService.sol";
import { IYoBridgeRouteRegistry } from "../src/interfaces/IYoBridgeRouteRegistry.sol";
import { IYoRegistry } from "../src/interfaces/IYoRegistry.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys the immutable {YoCctpxAdapter} bound to the chain's CCTPx `CrossChainTokenService`,
///         EURC and its CCTPx `tokenId`, the shared {YoBridgeRouteRegistry}, and the max native fee.
///         EURC-only by construction; destinations are gated by the route registry (keyed on Circle
///         domain ids). The deploy is deterministic (CREATE2 with the versioned `SALT`), so
///         {predictAddress} gives the address before the deploy, for the Safe batch
///         ({Configure_CctpxVault}).
///
///         The address is a hash of the creation code, so it changes with any change to the bytecode: the
///         compiler settings (`FOUNDRY_PROFILE`; `just deploy` uses `optimized`) and, because
///         `bytecode_hash = "ipfs"` embeds the metadata hash, the exact source text (comments included) of
///         every file in the adapter's import closure. Runbook: deploy from the merged commit with
///         `EXPECTED_ADAPTER` set to the adapter address in the Safe batch, or build the batch after the deploy.
///
///         Post-deploy operational steps (multisig, per vault), written by {Configure_CctpxVault}:
///           - `approvalRegistry.setApproval(vault, eurc, adapter, cap)`; the operator then calls
///             `vault.approveToken(eurc, adapter, amount)` before a transfer.
///           - `routeRegistry.setRoute(vault, adapter, eurc, destDomain, recipient, bytes32(0), true)`.
///           - Grant the operator role the `crossChainTransfer` selector on the vault's authority.
///           - Fund the vault with ETH: it pays each transfer's fee as `manage` value.
///
///         Run:
///           YO_REGISTRY=0x... YO_BRIDGE_ROUTE_REGISTRY=0x... FOUNDRY_PROFILE=optimized \
///               forge script script/Deploy_CctpxAdapter.s.sol --rpc-url base -vvv
///
///         Required env vars:
///           - YO_REGISTRY:               live YoRegistry proxy (adapter `rescue` auth).
///           - YO_BRIDGE_ROUTE_REGISTRY:  deployed {YoBridgeRouteRegistry} on this chain.
///         Optional env vars:
///           - EXPECTED_ADAPTER:                                the address the Safe batch targets; the script
///                                                              reverts before the deploy unless it predicts it.
///           - CCTPX_TOKEN_SERVICE, EURC, CCTPX_EURC_TOKEN_ID: override the chain-pinned values.
///           - ETH_FROM, MNEMONIC:                              broadcaster key (see {BaseScript}).
contract Deploy_CctpxAdapter is BaseScript {
    error PredictedAddressMismatch(address expected, address predicted);
    error ServiceNotDeployed(uint256 chainId, address service);
    error UnexpectedAddress(address predicted, address deployed);

    function run() public returns (YoCctpxAdapter adapter) {
        adapter =
            deploy(IYoBridgeRouteRegistry(vm.envAddress("YO_BRIDGE_ROUTE_REGISTRY")), IYoRegistry(getYoRegistry()));
    }

    /// @notice Deploy the adapter for `routeRegistry` and `yoRegistry` at {predictAddress}. Reverts before the
    ///         deploy when `EXPECTED_ADAPTER` is set to another address.
    function deploy(
        IYoBridgeRouteRegistry routeRegistry,
        IYoRegistry yoRegistry
    )
        public
        returns (YoCctpxAdapter adapter)
    {
        address service = getCctpxTokenService();
        if (service.code.length == 0) {
            revert ServiceNotDeployed(chainId, service);
        }
        address predicted = predictAddress(routeRegistry, yoRegistry);
        address expected = vm.envOr({ name: "EXPECTED_ADAPTER", defaultValue: address(0) });
        if (expected != address(0) && expected != predicted) {
            revert PredictedAddressMismatch(expected, predicted);
        }

        vm.startBroadcast(broadcaster);
        adapter = new YoCctpxAdapter{ salt: SALT }(
            ICrossChainTokenService(service),
            IERC20(getEURC()),
            getCctpxEurcTokenId(),
            routeRegistry,
            getCctpxMaxNativeFee(),
            yoRegistry
        );
        vm.stopBroadcast();
        if (address(adapter) != predicted) {
            revert UnexpectedAddress(predicted, address(adapter));
        }

        console2.log("=== YO CCTPx Adapter Deployed ===");
        console2.log("Chain ID:                  ", chainId);
        console2.log("Version:                   ", YO_VERSION);
        console2.log("Salt:                      ");
        console2.logBytes32(SALT);
        console2.log("");
        console2.log("YoCctpxAdapter:            ", address(adapter));
        console2.log("CCTPx CrossChainTokenService:", service);
        console2.log("EURC:                      ", address(adapter.token()));
        console2.log("EURC tokenId:              ");
        console2.logBytes32(adapter.tokenId());
        console2.log("Max native fee (wei):      ", adapter.maxNativeFee());
        console2.log("YoBridgeRouteRegistry:     ", address(routeRegistry));
        console2.log("YoRegistry (existing):     ", address(yoRegistry));
    }

    /// @notice The adapter's creation code with this chain's constructor arguments.
    function initCode(IYoBridgeRouteRegistry routeRegistry, IYoRegistry yoRegistry) public view returns (bytes memory) {
        return abi.encodePacked(
            type(YoCctpxAdapter).creationCode,
            abi.encode(
                getCctpxTokenService(),
                getEURC(),
                getCctpxEurcTokenId(),
                routeRegistry,
                getCctpxMaxNativeFee(),
                yoRegistry
            )
        );
    }

    /// @notice The adapter's CREATE2 address on this chain: the canonical CREATE2 factory, `SALT`, and
    ///         {initCode}. EURC has a different address on each chain, so each chain gets its own address.
    function predictAddress(IYoBridgeRouteRegistry routeRegistry, IYoRegistry yoRegistry)
        public
        view
        returns (address)
    {
        return vm.computeCreate2Address(SALT, keccak256(initCode(routeRegistry, yoRegistry)));
    }
}
