// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { console2 } from "forge-std/src/console2.sol";

import { YoUSDEdge } from "../src/YoUSDEdge.sol";

import { BaseScript } from "./Base.s.sol";
import { ChainId } from "./ChainId.sol";

/// @notice Deploys the {YoUSDEdge} implementation and emits the timelock calldata to rebrand the
///         yoloUSD vault to "yoUSD Edge" on Ethereum, Base, and Arbitrum.
///
///         The vault proxy (same address on all three chains) is a TransparentUpgradeableProxy
///         whose ProxyAdmin is owned by an OZ {TimelockController} (2-day min delay). The rebrand
///         is therefore a two-step, time-locked operation performed by the proposer multisig:
///           1. `schedule(...)` — queue `ProxyAdmin.upgradeAndCall(proxy, impl, reinitializeName())`.
///           2. After the delay elapses, `execute(...)` the SAME operation. `upgradeAndCall`
///              installs the new implementation and runs `reinitializeName()` (reinitializer(4))
///              atomically, so the name/symbol flip to "yoUSD Edge" with no front-run window.
///
///         This script only deploys the implementation (idempotent CREATE2) and prints / writes the
///         calldata; it never touches the timelock itself. Run it once per chain.
///
///         Optional env vars:
///           - YO_VAULT_PROXY:   override the vault proxy (defaults to the canonical address).
///           - YO_USD_EDGE_IMPL: reuse an already-deployed {YoUSDEdge} implementation.
///           - TIMELOCK_OP_SALT: bytes32 operation salt (defaults to keccak256("yoUSD-Edge-rebrand")).
///           - TIMELOCK_DELAY:   schedule delay in seconds (defaults to the timelock min delay;
///                               must be >= min delay).
///           - SAFE_PROPOSER:    proposer Safe written into the batch metadata.
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}).
contract Upgrade_YoUSDEdge is BaseScript {
    error DelayBelowMinimum(uint256 delay, uint256 minDelay);

    /// @dev The yoloUSD vault proxy. Same address on Ethereum, Base, and Arbitrum.
    address internal constant VAULT_PROXY = 0x5DD8BFa6C5C68D05d25EF6143E05C11E26c4cDB7;

    /// @dev Proposer Safe holding PROPOSER_ROLE on the timelock (verified on all three chains).
    address internal constant DEFAULT_PROPOSER_SAFE = 0x67b6F699F1c8040414032a3C2C88a54db144FCd2;

    struct RebrandPlan {
        address proxy;
        address newImpl;
        address proxyAdmin;
        address timelock;
        address proposerSafe;
        uint256 delay;
        bytes32 opSalt;
        bytes32 opId;
        bytes reinitCall;
        bytes upgradeCall;
        bytes scheduleCall;
        bytes executeCall;
    }

    function run() public returns (RebrandPlan memory plan) {
        plan.proxy = vm.envOr({ name: "YO_VAULT_PROXY", defaultValue: VAULT_PROXY });
        plan.proxyAdmin = _readProxyAdmin(plan.proxy);
        plan.timelock = ProxyAdmin(plan.proxyAdmin).owner();
        plan.proposerSafe = vm.envOr({ name: "SAFE_PROPOSER", defaultValue: DEFAULT_PROPOSER_SAFE });
        plan.opSalt = vm.envOr({ name: "TIMELOCK_OP_SALT", defaultValue: keccak256("yoUSD-Edge-rebrand") });

        uint256 minDelay = TimelockController(payable(plan.timelock)).getMinDelay();
        plan.delay = vm.envOr({ name: "TIMELOCK_DELAY", defaultValue: minDelay });
        if (plan.delay < minDelay) {
            revert DelayBelowMinimum(plan.delay, minDelay);
        }

        vm.startBroadcast(broadcaster);
        plan.newImpl = _getOrDeployImplementation();
        vm.stopBroadcast();

        _buildCalldata(plan);
        _log(plan);
        _writeSafeBatches(plan);
    }

    /// @dev Fills the operation calldata. The timelock schedules and later executes the SAME tuple
    ///      `(proxyAdmin, 0, upgradeCall, predecessor=0, opSalt)`; the op id is derived from it.
    function _buildCalldata(RebrandPlan memory plan) internal pure {
        plan.reinitCall = abi.encodeCall(YoUSDEdge.reinitializeName, ());
        plan.upgradeCall = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(plan.proxy), plan.newImpl, plan.reinitCall)
        );
        plan.scheduleCall = abi.encodeCall(
            TimelockController.schedule,
            (plan.proxyAdmin, uint256(0), plan.upgradeCall, bytes32(0), plan.opSalt, plan.delay)
        );
        plan.executeCall = abi.encodeCall(
            TimelockController.execute, (plan.proxyAdmin, uint256(0), plan.upgradeCall, bytes32(0), plan.opSalt)
        );
        plan.opId = TimelockController(payable(plan.timelock))
            .hashOperation(plan.proxyAdmin, uint256(0), plan.upgradeCall, bytes32(0), plan.opSalt);
    }

    /// @dev Resolution order: `YO_USD_EDGE_IMPL` env override -> existing code at the deterministic
    ///      CREATE2 address -> fresh deploy. Makes re-runs idempotent across chains (the impl has no
    ///      constructor args, so its address is identical everywhere).
    function _getOrDeployImplementation() internal returns (address impl) {
        impl = vm.envOr({ name: "YO_USD_EDGE_IMPL", defaultValue: address(0) });
        if (impl != address(0)) {
            return impl;
        }
        impl = vm.computeCreate2Address(SALT, keccak256(type(YoUSDEdge).creationCode));
        if (impl.code.length == 0) {
            impl = address(new YoUSDEdge{ salt: SALT }());
        }
    }

    function _writeSafeBatches(RebrandPlan memory plan) internal {
        string memory chain = _chainName();
        _writeBatch(
            plan,
            chain,
            "schedule",
            plan.scheduleCall,
            "Schedule yoUSD Edge rebrand: timelock.schedule of ProxyAdmin.upgradeAndCall(vault, YoUSDEdge, reinitializeName)"
        );
        _writeBatch(
            plan,
            chain,
            "execute",
            plan.executeCall,
            "Execute yoUSD Edge rebrand after the timelock delay elapses (same operation params as the schedule batch)"
        );
    }

    function _writeBatch(
        RebrandPlan memory plan,
        string memory chain,
        string memory action,
        bytes memory data,
        string memory description
    )
        internal
    {
        string memory json = _safeBatchJson(plan, action, data, description);
        string memory path = string.concat("script/safe-batches/yo-", chain, "-yousd-edge-", action, "-safe.json");
        vm.writeFile(path, json);
        console2.log("Wrote Safe batch:", path);
    }

    function _safeBatchJson(
        RebrandPlan memory plan,
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
            "    \"name\": \"YO yoUSD Edge rebrand (",
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
        revert ChainNotSupported("YoUSDEdge rebrand", chainId);
    }

    function _log(RebrandPlan memory plan) internal view {
        console2.log("=== yoUSD Edge rebrand (yoloUSD -> yoUSD Edge) ===");
        console2.log("Chain ID:            ", chainId);
        console2.log("Version:             ", YO_VERSION);
        console2.log("Vault proxy:         ", plan.proxy);
        console2.log("New implementation:  ", plan.newImpl);
        console2.log("ProxyAdmin:          ", plan.proxyAdmin);
        console2.log("Timelock:            ", plan.timelock);
        console2.log("Delay (s):           ", plan.delay);
        console2.log("Operation id:        ");
        console2.logBytes32(plan.opId);
        console2.log("");
        console2.log("=== Step 1: PROPOSER signs on the timelock to SCHEDULE ===");
        console2.log("Call ->", plan.timelock);
        console2.log("  fn:      TimelockController.schedule(proxyAdmin, 0, upgradeCall, 0, opSalt, delay)");
        console2.log("  calldata:");
        console2.logBytes(plan.scheduleCall);
        console2.log("");
        console2.log("=== Step 2: after the delay, EXECUTE the same operation ===");
        console2.log("Call ->", plan.timelock);
        console2.log("  fn:      TimelockController.execute(proxyAdmin, 0, upgradeCall, 0, opSalt)");
        console2.log("  calldata:");
        console2.logBytes(plan.executeCall);
        console2.log("");
        console2.log("Inner ProxyAdmin.upgradeAndCall(proxy, newImpl, reinitializeName()) calldata:");
        console2.logBytes(plan.upgradeCall);
    }
}
