// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { console2 } from "forge-std/src/console2.sol";

import { YoGateway } from "../src/YoGateway.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys the V3 YoGateway implementation and emits the multisig calldata to upgrade an
///         existing V2 proxy. The V2 → V3 transition is purely a reentrancy-mechanism swap
///         (`ReentrancyGuardUpgradeable` → `ReentrancyGuardTransient`); storage layout (slot 0 =
///         `registry`) is unchanged, so no re-init is needed.
///
///         Required env vars:
///           - YO_GATEWAY_PROXY: address of the existing YoGateway proxy on the target chain.
///
///         Optional env vars:
///           - EXECUTE_UPGRADE: set to "true" to attempt the upgrade as the broadcaster (only
///                              works when the broadcaster is the ProxyAdmin owner — usually
///                              limited to fork rehearsals).
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}).
contract Upgrade_YoGateway_V3 is BaseScript {
    function run() public returns (YoGateway newImpl) {
        address proxy = vm.envAddress("YO_GATEWAY_PROXY");

        vm.startBroadcast(broadcaster);
        newImpl = new YoGateway{ salt: SALT }();
        vm.stopBroadcast();

        address proxyAdmin = _readProxyAdmin(proxy);
        bytes memory upgradeCall =
            abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(proxy), address(newImpl), ""));

        _log(proxy, address(newImpl), proxyAdmin, upgradeCall);

        if (vm.envOr({ name: "EXECUTE_UPGRADE", defaultValue: false })) {
            vm.startBroadcast(broadcaster);
            ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), address(newImpl), "");
            vm.stopBroadcast();
            console2.log("");
            console2.log("[EXECUTE_UPGRADE=true] Upgrade performed by broadcaster.");
        }
    }

    function _log(address proxy, address newImpl, address proxyAdmin, bytes memory upgradeCall) internal view {
        console2.log("=== YoGateway V3 Upgrade ===");
        console2.log("Chain ID:           ", chainId);
        console2.log("Version:            ", YO_VERSION);
        console2.log("Proxy:              ", proxy);
        console2.log("New implementation: ", newImpl);
        console2.log("ProxyAdmin:         ", proxyAdmin);
        console2.log("");
        console2.log("=== Multisig batch (sign on the ProxyAdmin owner) ===");
        console2.log("Call -> ", proxyAdmin);
        console2.log("  fn:      ProxyAdmin.upgradeAndCall(proxy, newImpl, '')");
        console2.log("  calldata:");
        console2.logBytes(upgradeCall);
    }
}
