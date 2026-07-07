// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console2 } from "forge-std/src/console2.sol";

import { IAuthority } from "../src/interfaces/IAuthority.sol";
import { IYoApprovalRegistry } from "../src/interfaces/IYoApprovalRegistry.sol";
import { IYoRegistry } from "../src/interfaces/IYoRegistry.sol";
import { YoVault } from "../src/YoVault.sol";

import { BaseScript } from "./Base.s.sol";
import { UninitializedStub } from "./UninitializedStub.sol";

/// @notice Deploys a brand-new {YoVault} (implementation + transparent proxy) and configures it in
///         a single broadcast. This is for spinning up a fresh vault — upgrading an existing proxy
///         is handled by {Upgrade_YoVault_V3}.
///
///         Two deployment modes:
///
///         Single-chain (default): the proxy is deployed with the `initialize` calldata in its
///         constructor. Simple and atomic, but the proxy address depends on the chain's asset /
///         owner, so the same vault lands at different addresses on different chains.
///
///         Cross-chain deterministic (`CROSS_CHAIN=true`): the proxy address must be identical on
///         every chain even though the underlying asset differs (e.g. USDC on Ethereum vs Base).
///         Chain-specific values are kept OUT of the proxy initcode:
///           1. Deploy the proxy pointing at {UninitializedStub} with a no-op `ping()` as init
///              data — its initcode depends only on (stub, broadcaster, salt), all chain-agnostic.
///           2. `ProxyAdmin.upgradeAndCall(proxy, yoVaultImpl, initialize(chainAsset, ...))` —
///              atomically installs the real implementation and initializes with this chain's
///              asset. The stub cannot be initialized, so there is no front-run window.
///           3. The ProxyAdmin starts broadcaster-owned (its initial owner is part of the proxy
///              initcode; per-chain multisigs would change the address) and is transferred to
///              `PROXY_ADMIN_OWNER` at the end.
///         For matching addresses, run with the same broadcaster, FOUNDRY_PROFILE, YO_VERSION, and
///         VAULT_SALT_TAG on every chain.
///
///         Both modes finish identically: bind the approval registry / authority when provided,
///         transfer vault ownership to `YO_OWNER`, and print the `YoRegistry.addYoVault(proxy)`
///         calldata the registry owner must sign — the gateway only routes deposits to registered
///         vaults.
///
///         Every step is idempotent: existing contracts are reused and already-performed upgrades
///         and config calls are skipped. To complete a partially failed broadcast, re-run the
///         script WITHOUT `--resume` (resume resends the failed transaction with the same gas
///         limit that made it fail).
///
///         Monad: cold state access is repriced upward and failed transactions are charged the
///         FULL gas limit, so Foundry's locally simulated estimate is too low for state-heavy
///         calls like `upgradeAndCall`+`initialize`. Pass `--gas-estimate-multiplier 300`.
///
///         Post-deploy operational steps (not performed here):
///           - Sign `addYoVault` on the YoRegistry owner multisig (calldata printed below).
///           - Point the NAV oracle publisher at the new vault — share conversions read
///             {YoVault.ORACLE_ADDRESS} and revert with `InvalidPrice` until a price is published.
///           - Fees default to zero; set `updateDepositFee` / `updateWithdrawFee` /
///             `updateFeeRecipient` from the owner if needed.
///
///         Required env vars:
///           - VAULT_ASSET:  address of the vault's underlying ERC-20 asset on this chain.
///           - VAULT_NAME:   ERC-20 name of the vault share token.
///           - VAULT_SYMBOL: ERC-20 symbol of the vault share token.
///           - YO_OWNER:     final vault owner (multisig). See {BaseScript.getYoOwner}.
///           - YO_REGISTRY:  YoRegistry proxy on the target chain (for the `addYoVault` calldata).
///
///         Optional env vars:
///           - CROSS_CHAIN:          "true" for the cross-chain deterministic mode. Default false.
///           - VAULT_SALT_TAG:       per-vault salt differentiator mixed into the proxy salt.
///                                   Defaults to VAULT_SYMBOL — set explicitly when symbols differ
///                                   across chains in cross-chain mode.
///           - YO_VAULT_IMPL:        reuse an already-deployed YoVault implementation.
///           - YO_APPROVAL_REGISTRY: YoApprovalRegistry to bind via `setApprovalRegistry`.
///           - YO_AUTHORITY:         IAuthority (e.g. RolesAuthority) to bind via `setAuthority`.
///           - PROXY_ADMIN_OWNER:    owner of the proxy's ProxyAdmin. Defaults to YO_OWNER.
///           - ETH_FROM, MNEMONIC:   broadcaster key (see {BaseScript}).
contract Deploy_YoVault is BaseScript {
    error ProxyHasUnexpectedImplementation(address proxy, address implementation);

    struct VaultDeployment {
        bool crossChain;
        address asset;
        address implementation;
        address proxy;
        address proxyAdmin;
        address proxyAdminOwner;
        address owner;
        address approvalRegistry;
        address authority;
        address yoRegistry;
        bytes32 proxySalt;
        bytes addYoVaultCall;
    }

    function run() public returns (VaultDeployment memory d) {
        string memory name = vm.envString("VAULT_NAME");
        string memory symbol = vm.envString("VAULT_SYMBOL");
        d.asset = vm.envAddress("VAULT_ASSET");
        d.owner = getYoOwner();
        d.proxyAdminOwner = vm.envOr({ name: "PROXY_ADMIN_OWNER", defaultValue: d.owner });
        d.approvalRegistry = vm.envOr({ name: "YO_APPROVAL_REGISTRY", defaultValue: address(0) });
        d.authority = vm.envOr({ name: "YO_AUTHORITY", defaultValue: address(0) });
        d.yoRegistry = getYoRegistry();
        d.crossChain = vm.envOr({ name: "CROSS_CHAIN", defaultValue: false });
        d.proxySalt = _proxySalt(symbol);

        vm.startBroadcast(broadcaster);

        d.implementation = _getOrDeployImplementation();

        // The broadcaster starts as the vault owner so `setApprovalRegistry` / `setAuthority` can
        // run in this same broadcast; ownership moves to the multisig as the final step. The vault
        // holds no assets during this window.
        bytes memory initData = abi.encodeCall(YoVault.initialize, (IERC20(d.asset), broadcaster, name, symbol));

        if (d.crossChain) {
            (d.proxy, d.proxyAdmin) = _deployProxyCrossChain(d.implementation, d.proxySalt, initData);
        } else {
            (d.proxy, d.proxyAdmin) =
                _deployProxySingleChain(d.implementation, d.proxyAdminOwner, d.proxySalt, initData);
        }

        _configureAndHandOver(d);

        vm.stopBroadcast();

        d.addYoVaultCall = abi.encodeCall(IYoRegistry.addYoVault, (d.proxy));

        _log(d, name, symbol);
    }

    /// @dev Single-chain mode: initialize calldata rides in the proxy constructor, so deployment
    ///      and initialization are a single atomic transaction. Skipped when the proxy already
    ///      exists at its deterministic address (idempotent re-run).
    function _deployProxySingleChain(
        address impl,
        address adminOwner,
        bytes32 proxySalt,
        bytes memory initData
    )
        internal
        returns (address proxy, address proxyAdmin)
    {
        bytes memory initcode =
            abi.encodePacked(type(TransparentUpgradeableProxy).creationCode, abi.encode(impl, adminOwner, initData));
        proxy = vm.computeCreate2Address(proxySalt, keccak256(initcode));
        if (proxy.code.length == 0) {
            proxy = address(new TransparentUpgradeableProxy{ salt: proxySalt }(impl, adminOwner, initData));
        }
        proxyAdmin = _readProxyAdmin(proxy);
    }

    /// @dev Cross-chain mode: the proxy initcode contains no chain-specific values (the stub and
    ///      broadcaster are identical on every chain), so CREATE2 yields the same proxy address
    ///      everywhere. The real implementation + chain-specific `initialize` are installed
    ///      atomically via `upgradeAndCall`; the stub has no initializer, so the proxy cannot be
    ///      front-run in between. Both steps are skipped when already performed, so a partially
    ///      failed broadcast can be completed by simply re-running the script.
    function _deployProxyCrossChain(
        address impl,
        bytes32 proxySalt,
        bytes memory initData
    )
        internal
        returns (address proxy, address proxyAdmin)
    {
        address stub = _getOrDeployStub();
        console2.log("Cross-chain mode: deploying proxy to deterministic address with stub implementation ", stub);

        bytes memory pingData = abi.encodeCall(UninitializedStub.ping, ());
        bytes memory initcode =
            abi.encodePacked(type(TransparentUpgradeableProxy).creationCode, abi.encode(stub, broadcaster, pingData));
        proxy = vm.computeCreate2Address(proxySalt, keccak256(initcode));
        if (proxy.code.length == 0) {
            proxy = address(new TransparentUpgradeableProxy{ salt: proxySalt }(stub, broadcaster, pingData));
        }
        proxyAdmin = _readProxyAdmin(proxy);

        address current = _readProxyImplementation(proxy);
        if (current == stub) {
            ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, initData);
            console2.log("Proxy deployed at %s with stub impl, then upgraded to YoVault impl %s", proxy, impl);
        } else if (current != impl) {
            revert ProxyHasUnexpectedImplementation(proxy, current);
        }
    }

    /// @dev Shared tail for both modes: bind optional registries, then hand the vault (and, in
    ///      cross-chain mode, the ProxyAdmin) over to their final owners. Every step checks the
    ///      live state first, so re-runs of partially completed deployments are no-ops for the
    ///      parts already done.
    function _configureAndHandOver(VaultDeployment memory d) internal {
        YoVault vault = YoVault(payable(d.proxy));

        if (d.approvalRegistry != address(0) && address(vault.approvalRegistry()) != d.approvalRegistry) {
            vault.setApprovalRegistry(IYoApprovalRegistry(d.approvalRegistry));
        }
        if (d.authority != address(0) && address(vault.authority()) != d.authority) {
            vault.setAuthority(IAuthority(d.authority));
        }
        if (d.owner != broadcaster && vault.owner() == broadcaster) {
            vault.transferOwnership(d.owner);
        }
        if (d.crossChain && d.proxyAdminOwner != broadcaster && ProxyAdmin(d.proxyAdmin).owner() == broadcaster) {
            ProxyAdmin(d.proxyAdmin).transferOwnership(d.proxyAdminOwner);
        }
    }

    /// @dev Resolution order: `YO_VAULT_IMPL` env override → existing code at the deterministic
    ///      CREATE2 address for the current version → fresh deploy. Makes the script idempotent
    ///      with respect to the implementation on chains where it already exists.
    function _getOrDeployImplementation() internal returns (address impl) {
        impl = vm.envOr({ name: "YO_VAULT_IMPL", defaultValue: address(0) });
        if (impl != address(0)) {
            return impl;
        }

        impl = vm.computeCreate2Address(SALT, keccak256(type(YoVault).creationCode));
        if (impl.code.length == 0) {
            impl = address(new YoVault{ salt: SALT }());
        }
    }

    /// @dev Idempotent stub deploy — every cross-chain vault on a chain shares one stub instance.
    function _getOrDeployStub() internal returns (address stub) {
        stub = vm.computeCreate2Address(SALT, keccak256(type(UninitializedStub).creationCode));
        if (stub.code.length == 0) {
            stub = address(new UninitializedStub{ salt: SALT }());
        }
    }

    /// @dev Mixes a per-vault tag into the versioned salt so multiple vaults can be deployed per
    ///      version. In cross-chain mode the proxy initcode is identical for every vault, making
    ///      this differentiation mandatory rather than cosmetic.
    function _proxySalt(string memory symbol) internal view returns (bytes32) {
        string memory tag = vm.envOr({ name: "VAULT_SALT_TAG", defaultValue: symbol });
        return keccak256(abi.encodePacked(SALT, tag));
    }

    function _log(VaultDeployment memory d, string memory name, string memory symbol) internal view {
        console2.log("=== New YoVault Deployed ===");
        console2.log("Mode:                ", d.crossChain ? "cross-chain deterministic" : "single-chain");
        console2.log("Chain ID:            ", chainId);
        console2.log("Version:             ", YO_VERSION);
        console2.log("Proxy salt:          ");
        console2.logBytes32(d.proxySalt);
        console2.log("Asset:               ", d.asset);
        console2.log("Name:                ", name);
        console2.log("Symbol:              ", symbol);
        console2.log("");
        console2.log("Implementation:      ", d.implementation);
        console2.log("Proxy (the vault):   ", d.proxy);
        console2.log("ProxyAdmin:          ", d.proxyAdmin);
        console2.log("ProxyAdmin owner:    ", d.proxyAdminOwner);
        console2.log("Vault owner:         ", d.owner);
        if (d.approvalRegistry != address(0)) {
            console2.log("ApprovalRegistry:    ", d.approvalRegistry);
        } else {
            console2.log("ApprovalRegistry:     (not set - approveToken disabled until bound)");
        }
        if (d.authority != address(0)) {
            console2.log("Authority:           ", d.authority);
        } else {
            console2.log("Authority:            (not set - only the owner passes requiresAuth)");
        }
        console2.log("");
        console2.log("=== Multisig step (sign on the YoRegistry owner) ===");
        console2.log("Call ->", d.yoRegistry);
        console2.log("  fn:      YoRegistry.addYoVault(proxy)");
        console2.log("  calldata:");
        console2.logBytes(d.addYoVaultCall);
        console2.log("");
        console2.log("Reminder: publish a NAV price for the new vault before opening deposits;");
        console2.log("share conversions revert with InvalidPrice until the oracle covers it.");
        if (d.crossChain) {
            console2.log("");
            console2.log("Cross-chain mode: repeat this run on the other chains with the SAME broadcaster,");
            console2.log("FOUNDRY_PROFILE, YO_VERSION, and VAULT_SALT_TAG to land at the same proxy address.");
        }
    }
}
