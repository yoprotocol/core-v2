// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { console2 } from "forge-std/src/console2.sol";

import { YoVault } from "../src/YoVault.sol";
import { YoVaultRename } from "../src/YoVaultRename.sol";

import { BaseScript } from "./Base.s.sol";
import { ChainId } from "./ChainId.sol";

/// @notice Deploys the {YoVaultRename} implementation and emits the timelock calldata to rename
///         every eligible vault on the current chain so each share token's ERC-20 `name` matches
///         its `symbol` (e.g. "yoVaultETH" -> "yoETH"). Generalizes the one-off
///         {Upgrade_YoUSDEdge} rebrand and batches all of a chain's renames into a SINGLE timelock
///         operation, so each network needs just one schedule transaction and one execute
///         transaction on the proposer multisig.
///
///         Every vault proxy is a TransparentUpgradeableProxy whose ProxyAdmin is owned by the same
///         OZ {TimelockController} (2-day min delay) on a given chain. The rename is a two-step,
///         time-locked batch operation:
///           1. `scheduleBatch(...)` — queue, for each vault, a
///              `ProxyAdmin.upgradeAndCall(proxy, impl, reinitializeName())`.
///           2. After the delay elapses, `executeBatch(...)` the SAME tuple. `upgradeAndCall`
///              installs the new implementation and runs `reinitializeName()` (reinitializer(3))
///              atomically per vault, so names flip with no front-run window. Symbols are preserved
///              because {YoVaultRename.reinitializeName} re-runs `__ERC20_init` with the live
///              `symbol()`.
///
///         The script reads on-chain state and only includes vaults whose `name != symbol` and that
///         are NOT paused — paused or already-correct vaults are skipped automatically. It only
///         deploys the implementation (idempotent CREATE2) and prints / writes the calldata; it
///         never touches the timelock itself. Run it once per chain.
///
///         Optional env vars:
///           - YO_VAULT_PROXIES:     comma-separated proxy list overriding the per-chain default.
///           - YO_VAULT_RENAME_IMPL: reuse an already-deployed {YoVaultRename} implementation.
///           - TIMELOCK_OP_SALT:     bytes32 batch operation salt.
///           - TIMELOCK_DELAY:       schedule delay in seconds (defaults to the timelock min delay;
///                                   must be >= min delay).
///           - SAFE_PROPOSER:        proposer Safe written into the batch metadata.
///           - ETH_FROM, MNEMONIC:   broadcaster key (see {BaseScript}).
contract Upgrade_YoVaultRename is BaseScript {
    error DelayBelowMinimum(uint256 delay, uint256 minDelay);
    error NoVaultsToRename(uint256 chainId);
    error MixedTimelocks(address expected, address found, address proxy);

    /// @dev Canonical vault proxies (same address on every chain via cross-chain CREATE2).
    address internal constant YO_ETH = 0x3A43AEC53490CB9Fa922847385D82fe25d0E9De7;
    address internal constant YO_BTC = 0xbCbc8cb4D1e8ED048a6276a5E94A3e952660BcbC;
    address internal constant YO_USD = 0x0000000f2eB9f69274678c76222B35eEc7588a65;
    address internal constant YO_EUR = 0x50c749aE210D3977ADC824AE11F3c7fd10c871e9;

    struct BatchPlan {
        address newImpl;
        address timelock;
        address proposerSafe;
        uint256 delay;
        bytes32 opSalt;
        bytes32 opId;
        address[] proxies; // included vaults (name != symbol, not paused)
        string[] symbols; // their symbols == target names, for logging
        address[] targets; // each vault's ProxyAdmin
        uint256[] values; // all zero
        bytes[] payloads; // upgradeAndCall(proxy, impl, reinitializeName())
        bytes scheduleCall;
        bytes executeCall;
    }

    function run() public returns (BatchPlan memory plan) {
        vm.startBroadcast(broadcaster);
        plan.newImpl = _getOrDeployImplementation();
        vm.stopBroadcast();

        _selectVaults(plan);
        if (plan.proxies.length == 0) {
            revert NoVaultsToRename(chainId);
        }

        plan.proposerSafe = vm.envOr({ name: "SAFE_PROPOSER", defaultValue: address(0) });
        plan.opSalt = vm.envOr({ name: "TIMELOCK_OP_SALT", defaultValue: keccak256("yo-rename-batch") });

        uint256 minDelay = TimelockController(payable(plan.timelock)).getMinDelay();
        plan.delay = vm.envOr({ name: "TIMELOCK_DELAY", defaultValue: minDelay });
        if (plan.delay < minDelay) {
            revert DelayBelowMinimum(plan.delay, minDelay);
        }

        _buildCalldata(plan);
        _log(plan);
        _writeSafeBatches(plan);
    }

    /// @dev Reads each candidate proxy and keeps only the ones that still need renaming (`name !=
    ///      symbol`) and are not paused. Populates the parallel `proxies`/`symbols`/`targets`/
    ///      `values`/`payloads` arrays and resolves the shared timelock, asserting every included
    ///      vault's ProxyAdmin is owned by the same one (required for a single batch).
    function _selectVaults(BatchPlan memory plan) internal view {
        address[] memory candidates = _candidates();
        uint256 count;
        // First pass: count eligible vaults so the plan arrays can be sized exactly.
        bool[] memory eligible = new bool[](candidates.length);
        for (uint256 i; i < candidates.length; ++i) {
            if (_needsRename(candidates[i])) {
                eligible[i] = true;
                ++count;
            }
        }

        plan.proxies = new address[](count);
        plan.symbols = new string[](count);
        plan.targets = new address[](count);
        plan.values = new uint256[](count);
        plan.payloads = new bytes[](count);

        uint256 j;
        for (uint256 i; i < candidates.length; ++i) {
            if (!eligible[i]) {
                continue;
            }
            address proxy = candidates[i];
            address proxyAdmin = _readProxyAdmin(proxy);
            address timelock = ProxyAdmin(proxyAdmin).owner();
            if (plan.timelock == address(0)) {
                plan.timelock = timelock;
            } else if (timelock != plan.timelock) {
                revert MixedTimelocks(plan.timelock, timelock, proxy);
            }

            plan.proxies[j] = proxy;
            plan.symbols[j] = IERC20Metadata(proxy).symbol();
            plan.targets[j] = proxyAdmin;
            plan.values[j] = 0;
            plan.payloads[j] = abi.encodeCall(
                ProxyAdmin.upgradeAndCall,
                (ITransparentUpgradeableProxy(proxy), plan.newImpl, abi.encodeCall(YoVaultRename.reinitializeName, ()))
            );
            ++j;
        }
    }

    /// @dev A vault needs renaming when it has code, is not paused, and its `name` differs from its
    ///      `symbol`.
    function _needsRename(address proxy) internal view returns (bool) {
        if (proxy.code.length == 0) {
            return false;
        }
        if (YoVault(payable(proxy)).paused()) {
            return false;
        }
        IERC20Metadata token = IERC20Metadata(proxy);
        return keccak256(bytes(token.name())) != keccak256(bytes(token.symbol()));
    }

    /// @dev Per-chain default candidate set (overridable via `YO_VAULT_PROXIES`). yoBTC and yoEUR
    ///      are Ethereum/Base only; yoUSD additionally lives on Arbitrum.
    function _candidates() internal view returns (address[] memory) {
        address[] memory envProxies = vm.envOr({ name: "YO_VAULT_PROXIES", delim: ",", defaultValue: new address[](0) });
        if (envProxies.length != 0) {
            return envProxies;
        }
        if (chainId == ChainId.ETHEREUM || chainId == ChainId.BASE) {
            address[] memory all = new address[](4);
            all[0] = YO_ETH;
            all[1] = YO_BTC;
            all[2] = YO_USD;
            all[3] = YO_EUR;
            return all;
        }
        if (chainId == ChainId.ARBITRUM) {
            address[] memory arb = new address[](1);
            arb[0] = YO_USD;
            return arb;
        }
        revert ChainNotSupported("YoVault rename", chainId);
    }

    /// @dev Builds the `scheduleBatch` / `executeBatch` calldata for the whole chain in one
    ///      timelock operation. Both calls share the SAME `(targets, values, payloads, 0, opSalt)`
    ///      tuple; the op id is derived from it.
    function _buildCalldata(BatchPlan memory plan) internal pure {
        plan.scheduleCall = abi.encodeCall(
            TimelockController.scheduleBatch,
            (plan.targets, plan.values, plan.payloads, bytes32(0), plan.opSalt, plan.delay)
        );
        plan.executeCall = abi.encodeCall(
            TimelockController.executeBatch, (plan.targets, plan.values, plan.payloads, bytes32(0), plan.opSalt)
        );
        plan.opId = TimelockController(payable(plan.timelock))
            .hashOperationBatch(plan.targets, plan.values, plan.payloads, bytes32(0), plan.opSalt);
    }

    /// @dev Resolution order: `YO_VAULT_RENAME_IMPL` env override -> existing code at the
    ///      deterministic CREATE2 address -> fresh deploy. Makes re-runs idempotent across chains
    ///      (the impl has no constructor args, so its address is identical everywhere).
    function _getOrDeployImplementation() internal returns (address impl) {
        impl = vm.envOr({ name: "YO_VAULT_RENAME_IMPL", defaultValue: address(0) });
        if (impl != address(0)) {
            return impl;
        }
        impl = vm.computeCreate2Address(SALT, keccak256(type(YoVaultRename).creationCode));
        if (impl.code.length == 0) {
            impl = address(new YoVaultRename{ salt: SALT }());
        }
    }

    function _writeSafeBatches(BatchPlan memory plan) internal {
        string memory chain = _chainName();
        _writeBatch(
            plan,
            chain,
            "schedule",
            plan.scheduleCall,
            "Schedule vault renames: timelock.scheduleBatch of "
            "ProxyAdmin.upgradeAndCall(vault, YoVaultRename, reinitializeName) for all eligible vaults"
        );
        _writeBatch(
            plan,
            chain,
            "execute",
            plan.executeCall,
            "Execute vault renames after the timelock delay elapses (same batch params as the schedule transaction)"
        );
    }

    function _writeBatch(
        BatchPlan memory plan,
        string memory chain,
        string memory action,
        bytes memory data,
        string memory description
    )
        internal
    {
        string memory json = _safeBatchJson(plan, action, data, description);
        string memory path = string.concat("script/safe-batches/yo-", chain, "-rename-", action, "-safe.json");
        vm.writeFile(path, json);
        console2.log("Wrote Safe batch:", path);
    }

    function _safeBatchJson(
        BatchPlan memory plan,
        string memory action,
        bytes memory data,
        string memory description
    )
        internal
        view
        returns (string memory)
    {
        string memory meta = string.concat(
            "{\n",
            "  \"version\": \"1.0\",\n",
            "  \"chainId\": \"",
            vm.toString(chainId),
            "\",\n",
            "  \"createdAt\": ",
            vm.toString(block.timestamp * 1000),
            ",\n",
            "  \"meta\": {\n",
            "    \"name\": \"YO vault renames (",
            action,
            ")\",\n",
            "    \"description\": \"",
            description,
            "\",\n",
            "    \"txBuilderVersion\": \"1.18.0\",\n",
            "    \"createdFromSafeAddress\": \"",
            vm.toString(plan.proposerSafe),
            "\",\n",
            "    \"createdFromOwnerAddress\": \"\"\n",
            "  },\n"
        );
        string memory txs = string.concat(
            "  \"transactions\": [\n",
            "    {\n",
            "      \"to\": \"",
            vm.toString(plan.timelock),
            "\",\n",
            "      \"value\": \"0\",\n",
            "      \"data\": \"",
            vm.toString(data),
            "\",\n",
            "      \"contractMethod\": null,\n",
            "      \"contractInputsValues\": null\n",
            "    }\n",
            "  ]\n",
            "}\n"
        );
        return string.concat(meta, txs);
    }

    function _chainName() internal view returns (string memory) {
        if (chainId == ChainId.ETHEREUM) {
            return "ethereum";
        }
        if (chainId == ChainId.BASE) {
            return "base";
        }
        if (chainId == ChainId.ARBITRUM) {
            return "arbitrum";
        }
        revert ChainNotSupported("YoVault rename", chainId);
    }

    function _log(BatchPlan memory plan) internal view {
        console2.log("=== YoVault renames (name -> symbol), batched per chain ===");
        console2.log("Chain ID:            ", chainId);
        console2.log("Version:             ", YO_VERSION);
        console2.log("New implementation:  ", plan.newImpl);
        console2.log("Timelock:            ", plan.timelock);
        console2.log("Delay (s):           ", plan.delay);
        console2.log("Vaults renamed:      ", plan.proxies.length);
        for (uint256 i; i < plan.proxies.length; ++i) {
            console2.log(string.concat("  - ", plan.symbols[i]), plan.proxies[i]);
        }
        console2.log("Batch operation id:  ");
        console2.logBytes32(plan.opId);
        console2.log("");
        console2.log("=== Step 1: PROPOSER signs on the timelock to SCHEDULE ===");
        console2.log("Call ->", plan.timelock);
        console2.log("  fn:      TimelockController.scheduleBatch(targets, values, payloads, 0, opSalt, delay)");
        console2.log("  calldata:");
        console2.logBytes(plan.scheduleCall);
        console2.log("");
        console2.log("=== Step 2: after the delay, EXECUTE the same batch ===");
        console2.log("Call ->", plan.timelock);
        console2.log("  fn:      TimelockController.executeBatch(targets, values, payloads, 0, opSalt)");
        console2.log("  calldata:");
        console2.logBytes(plan.executeCall);
    }
}
