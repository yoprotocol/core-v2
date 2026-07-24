// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { console2 } from "forge-std/src/console2.sol";

import { IYoApprovalRegistry } from "../src/interfaces/IYoApprovalRegistry.sol";
import { YoVault } from "../src/YoVault.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys the V3 YoVault implementation and emits the multisig calldata to upgrade an
///         existing V2 proxy to it. Designed for the canonical V2 → V3 transition; storage layout
///         is preserved (slots 0-8 unchanged; slot 9 introduces `approvalRegistry`).
///
///         The actual `upgradeAndCall` is a privileged operation performed by the ProxyAdmin's
///         owner (typically a multisig or timelock). This script:
///           1. Deploys the new implementation (broadcast).
///           2. Prints the calldata the admin should sign:
///                a. `ProxyAdmin.upgradeAndCall(proxy, newImpl, "")` — perform the upgrade.
///                b. `proxy.setApprovalRegistry(approvalRegistry)` — bind the new registry
///                   pointer. Must come from the vault owner (separate signer chain from the
///                   ProxyAdmin owner, even if both are the same multisig under the hood).
///
///         Required env vars:
///           - YO_VAULT_PROXY:     address of the existing YoVault proxy on the target chain.
///           - YO_APPROVAL_REGISTRY: address of the deployed YoApprovalRegistry (from
///                                   Deploy_V3_Stack), used in the post-upgrade `setApprovalRegistry`
///                                   call.
///
///         Optional env vars:
///           - EXECUTE_UPGRADE: set to "true" to attempt the upgrade as the broadcaster (only
///                              works when the broadcaster is the ProxyAdmin owner — usually
///                              limited to fork rehearsals).
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}).
contract Upgrade_YoVault_V3 is BaseScript {
    struct VaultUpgradePlan {
        address proxy;
        address newImpl;
        address proxyAdmin;
        address approvalRegistry;
        bytes upgradeCall;
        bytes bindApprovalRegistryCall;
    }

    function run() public returns (YoVault newImpl) {
        address proxy = vm.envAddress("YO_VAULT_PROXY");
        address approvalRegistry = vm.envAddress("YO_APPROVAL_REGISTRY");

        // The V3 YoVault implementation takes no constructor args, so its CREATE2 address is fixed by
        // (salt, bytecode) alone — the same on every chain and every run. Reuse it when already
        // deployed instead of re-broadcasting into a `CreateCollision`, keeping the script idempotent.
        address predicted = vm.computeCreate2Address(SALT, keccak256(type(YoVault).creationCode));
        if (predicted.code.length == 0) {
            vm.startBroadcast(broadcaster);
            newImpl = new YoVault{ salt: SALT }();
            vm.stopBroadcast();
        } else {
            newImpl = YoVault(payable(predicted));
            console2.log("YoVault V3 implementation already deployed; reusing:", predicted);
        }

        VaultUpgradePlan memory plan = VaultUpgradePlan({
            proxy: proxy,
            newImpl: address(newImpl),
            proxyAdmin: _readProxyAdmin(proxy),
            approvalRegistry: approvalRegistry,
            upgradeCall: abi.encodeCall(
                ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(proxy), address(newImpl), "")
            ),
            bindApprovalRegistryCall: abi.encodeCall(
                YoVault.setApprovalRegistry, (IYoApprovalRegistry(approvalRegistry))
            )
        });

        _log(plan);

        if (vm.envOr({ name: "EXECUTE_UPGRADE", defaultValue: false })) {
            vm.startBroadcast(broadcaster);
            ProxyAdmin(plan.proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), address(newImpl), "");
            YoVault(payable(proxy)).setApprovalRegistry(IYoApprovalRegistry(approvalRegistry));
            vm.stopBroadcast();
            console2.log("");
            console2.log("[EXECUTE_UPGRADE=true] Upgrade + setApprovalRegistry performed by broadcaster.");
        }
    }

    function _log(VaultUpgradePlan memory plan) internal view {
        console2.log("=== YoVault V3 Upgrade ===");
        console2.log("Chain ID:           ", chainId);
        console2.log("Version:            ", YO_VERSION);
        console2.log("Proxy:              ", plan.proxy);
        console2.log("New implementation: ", plan.newImpl);
        console2.log("ProxyAdmin:         ", plan.proxyAdmin);
        console2.log("ApprovalRegistry:   ", plan.approvalRegistry);
        console2.log("");
        console2.log("=== Multisig batch (sign on the ProxyAdmin owner) ===");
        console2.log("Call 1 ->", plan.proxyAdmin);
        console2.log("  fn:      ProxyAdmin.upgradeAndCall(proxy, newImpl, '')");
        console2.log("  calldata:");
        console2.logBytes(plan.upgradeCall);
        console2.log("");
        console2.log("=== Multisig batch (sign on the YoVault owner) ===");
        console2.log("Call 2 ->", plan.proxy);
        console2.log("  fn:      YoVault.setApprovalRegistry(approvalRegistry)");
        console2.log("  calldata:");
        console2.logBytes(plan.bindApprovalRegistryCall);
    }
}
