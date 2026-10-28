// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console2 } from "forge-std/src/console2.sol";

import { YoMidnightAdapter } from "../src/adapters/midnight/YoMidnightAdapter.sol";
import { IYoApprovalRegistry } from "../src/interfaces/IYoApprovalRegistry.sol";
import { IYoRegistry } from "../src/interfaces/IYoRegistry.sol";
import { IMidnight } from "../src/vendor/morpho-midnight/interfaces/IMidnight.sol";
import { YoVault } from "../src/YoVault.sol";

import {
    IBlueAuthorization,
    IBlueBuyCallbackAuthorization,
    IOwnable,
    IRolesAuthorityMidnight,
    MidnightSafeBatch
} from "./MidnightSafeBatch.sol";

/// @notice Writes the admin Safe batch that removes a vault's access to a retired {YoMidnightAdapter}, as a
///         Safe Transaction Builder JSON in `script/safe-batches/`. Nothing is broadcast: run with `--rpc-url`
///         only. The script executes the batch as the Safe on the fork, checks the result, and then writes the
///         file.
///
///         The vault, the shared `RolesAuthority`, and the approval registry must have the same owner: the Safe
///         that executes the batch. The batch:
///           1. `setRoleCapability(operatorRole, adapter, selector, false)` for the six adapter selectors. The
///              capabilities are per adapter, not per vault: the script keeps them when another YoRegistry vault
///              still authorizes the adapter on Midnight, or its salt-0 callback still authorizes it on Blue.
///           2. `approvalRegistry.setApproval(vault, asset, adapter, 0)`.
///           3. `vault.approveToken(asset, adapter, 0)` when the allowance is not 0.
///           4. Vault-owned revocations, through `vault.manage` under a temporary role for the Safe:
///              `Midnight.setIsAuthorized(adapter, false)` and `callback.setAuthorization(adapter, false)`.
///         Each step is left out when the chain already has its result, so the script can run again.
///
///         The batch does not touch the market registry, the ratifier authorization, or the roots in the
///         `SetterRatifier`. Ratified roots stay fillable against the callback. After the batch, only another
///         adapter that the vault authorizes on Midnight and on the callback can unratify them, defund the
///         callback, or redeem credit. Name it in REPLACEMENT_ADAPTER, and the script requires that it is
///         authorized.
///
///         Run:
///           VAULT=0x... MIDNIGHT_ADAPTER=0x... \
///               forge script script/Revoke_MidnightAdapter.s.sol --rpc-url mainnet -vvv
///
///         Required env vars:
///           - VAULT:            the vault.
///           - MIDNIGHT_ADAPTER: the retired {YoMidnightAdapter}.
///         Optional env vars:
///           - REPLACEMENT_ADAPTER: the vault's new {YoMidnightAdapter}; default none.
///           - CALLBACK_SALT:       `BlueBuyCallbackFactory` salt of the vault's callback; default 0.
///           - OPERATOR_ROLE:       default 12.
///           - TEMP_ROLE:           role the Safe holds during the batch; default 250. Must not hold the Safe or
///                                  the batch's capabilities.
///           - BATCH_SLUG:          output file name `yo-<slug>-safe.json`; default "midnight-revoke".
contract Revoke_MidnightAdapter is MidnightSafeBatch {
    error ReplacementNotAuthorized(string what, address replacement);

    struct Inputs {
        YoVault vault;
        YoMidnightAdapter adapter;
        address replacement;
        bytes32 callbackSalt;
        uint8 operatorRole;
        uint8 tempRole;
    }

    function run() public {
        Inputs memory inputs = readInputs();
        Call[] memory calls = build(inputs);
        address safe = inputs.vault.owner();

        uint256 snapshot = vm.snapshotState();
        execute(safe, calls);
        verify(inputs);
        vm.revertToState(snapshot);

        string memory slug = vm.envOr({ name: "BATCH_SLUG", defaultValue: string("midnight-revoke") });
        _writeBatch(
            string.concat("script/safe-batches/yo-", slug, "-safe.json"),
            string.concat("Revoke Midnight adapter for ", inputs.vault.symbol()),
            safe,
            calls
        );
    }

    /// @notice The inputs from the env vars. See the contract NatSpec.
    function readInputs() public view returns (Inputs memory inputs) {
        inputs.vault = YoVault(payable(vm.envAddress("VAULT")));
        inputs.adapter = YoMidnightAdapter(vm.envAddress("MIDNIGHT_ADAPTER"));
        inputs.replacement = vm.envOr({ name: "REPLACEMENT_ADAPTER", defaultValue: address(0) });
        inputs.callbackSalt = vm.envOr({ name: "CALLBACK_SALT", defaultValue: bytes32(0) });
        inputs.operatorRole = uint8(vm.envOr({ name: "OPERATOR_ROLE", defaultValue: uint256(12) }));
        inputs.tempRole = uint8(vm.envOr({ name: "TEMP_ROLE", defaultValue: uint256(250) }));
    }

    /// @notice The batch calls, in order, after the preflight checks.
    function build(Inputs memory inputs) public view returns (Call[] memory calls) {
        address safe = _preflight(inputs);
        Call[] memory buffer = new Call[](64);
        uint256 n = _governanceCalls(inputs, !_usedByOtherVaults(inputs), buffer, 0);
        n = _ownedCalls(inputs, safe, buffer, n);
        calls = _trim(buffer, n);
    }

    /// @dev Operator capabilities (when `removeCapabilities`), approval cap, and allowance.
    function _governanceCalls(
        Inputs memory inputs,
        bool removeCapabilities,
        Call[] memory calls,
        uint256 n
    )
        internal
        view
        returns (uint256)
    {
        address adapter = address(inputs.adapter);
        address vault = address(inputs.vault);
        IRolesAuthorityMidnight authority = IRolesAuthorityMidnight(address(inputs.vault.authority()));

        bytes4[6] memory selectors = _operatorSelectors();
        for (uint256 i = 0; removeCapabilities && i < selectors.length; ++i) {
            if (authority.doesRoleHaveCapability(inputs.operatorRole, adapter, selectors[i])) {
                calls[n++] = Call(
                    address(authority),
                    abi.encodeCall(
                        IRolesAuthorityMidnight.setRoleCapability, (inputs.operatorRole, adapter, selectors[i], false)
                    )
                );
            }
        }

        IYoApprovalRegistry approvalRegistry = inputs.vault.approvalRegistry();
        address asset = inputs.vault.asset();
        if (approvalRegistry.maxApproval(vault, asset, adapter) != 0) {
            calls[n++] = Call(
                address(approvalRegistry), abi.encodeCall(IYoApprovalRegistry.setApproval, (vault, asset, adapter, 0))
            );
        }
        // The owner passes `requiresAuth` on `approveToken`.
        if (IERC20(asset).allowance(vault, adapter) != 0) {
            calls[n++] = Call(vault, abi.encodeCall(YoVault.approveToken, (asset, adapter, 0)));
        }
        return n;
    }

    /// @dev Vault-owned calls: `manage` checks the authority for the caller, also for the owner.
    function _ownedCalls(
        Inputs memory inputs,
        address safe,
        Call[] memory calls,
        uint256 n
    )
        internal
        view
        returns (uint256)
    {
        YoMidnightAdapter adapter = inputs.adapter;
        address vault = address(inputs.vault);
        IMidnight midnight = adapter.midnight();
        address callback = adapter.callbackFactory().callbackOf(vault, inputs.callbackSalt);
        Call[] memory owned = new Call[](2);
        uint256 m;
        if (midnight.isAuthorized(vault, address(adapter))) {
            owned[m++] =
                Call(address(midnight), abi.encodeCall(IMidnight.setIsAuthorized, (address(adapter), false, vault)));
        }
        if (
            callback != address(0)
                && IBlueAuthorization(address(adapter.morpho())).isAuthorized(callback, address(adapter))
        ) {
            owned[m++] = Call(
                callback, abi.encodeCall(IBlueBuyCallbackAuthorization.setAuthorization, (address(adapter), false))
            );
        }
        if (m > 0) {
            IRolesAuthorityMidnight authority = IRolesAuthorityMidnight(address(inputs.vault.authority()));
            n = _appendOwned(calls, n, owned, m, authority, vault, safe, inputs.tempRole);
        }
        return n;
    }

    /// @notice Revert unless the chain has the state that the batch sets.
    function verify(Inputs memory inputs) public view {
        YoMidnightAdapter adapter = inputs.adapter;
        address vault = address(inputs.vault);
        address safe = inputs.vault.owner();
        IRolesAuthorityMidnight authority = IRolesAuthorityMidnight(address(inputs.vault.authority()));
        IMidnight midnight = adapter.midnight();

        _require(!midnight.isAuthorized(vault, address(adapter)), "Midnight does not authorize the adapter");
        address callback = adapter.callbackFactory().callbackOf(vault, inputs.callbackSalt);
        _require(
            callback == address(0)
                || !IBlueAuthorization(address(adapter.morpho())).isAuthorized(callback, address(adapter)),
            "the callback does not authorize the adapter on Blue"
        );

        bytes4[6] memory selectors = _operatorSelectors();
        bool removeCapabilities = !_usedByOtherVaults(inputs);
        for (uint256 i = 0; removeCapabilities && i < selectors.length; ++i) {
            _require(
                !authority.doesRoleHaveCapability(inputs.operatorRole, address(adapter), selectors[i]),
                "no operator capability"
            );
        }
        address asset = inputs.vault.asset();
        _require(inputs.vault.approvalRegistry().maxApproval(vault, asset, address(adapter)) == 0, "approval cap 0");
        _require(IERC20(asset).allowance(vault, address(adapter)) == 0, "allowance 0");

        _requireTempRoleCleared(authority, safe, inputs.tempRole, address(midnight), callback);
    }

    function _preflight(Inputs memory inputs) internal view returns (address safe) {
        safe = inputs.vault.owner();
        IRolesAuthorityMidnight authority = IRolesAuthorityMidnight(address(inputs.vault.authority()));
        _requireOwner("authority", authority.owner(), safe);
        _requireOwner("approval registry", IOwnable(address(inputs.vault.approvalRegistry())).owner(), safe);

        address replacement = inputs.replacement;
        if (replacement == address(0)) {
            console2.log("No REPLACEMENT_ADAPTER: ratified roots stay fillable, and no adapter can manage them.");
            return safe;
        }
        address vault = address(inputs.vault);
        if (replacement.code.length == 0 || replacement == address(inputs.adapter)) {
            revert ReplacementNotAuthorized("code", replacement);
        }
        if (!inputs.adapter.midnight().isAuthorized(vault, replacement)) {
            revert ReplacementNotAuthorized("Midnight", replacement);
        }
        address callback = inputs.adapter.callbackFactory().callbackOf(vault, inputs.callbackSalt);
        if (
            callback != address(0)
                && !IBlueAuthorization(address(inputs.adapter.morpho())).isAuthorized(callback, replacement)
        ) {
            revert ReplacementNotAuthorized("callback", replacement);
        }
    }

    /// @dev Whether another YoRegistry vault authorizes the adapter on Midnight, or its salt-0 callback authorizes
    ///      it on Blue. Callbacks with other salts are not seen.
    function _usedByOtherVaults(Inputs memory inputs) internal view returns (bool) {
        address adapter = address(inputs.adapter);
        IMidnight midnight = inputs.adapter.midnight();
        IBlueAuthorization morpho = IBlueAuthorization(address(inputs.adapter.morpho()));
        address[] memory vaults = IYoRegistry(getYoRegistry()).listYoVaults();
        for (uint256 i = 0; i < vaults.length; ++i) {
            if (vaults[i] == address(inputs.vault)) {
                continue;
            }
            address callback = inputs.adapter.callbackFactory().callbackOf(vaults[i], bytes32(0));
            if (
                midnight.isAuthorized(vaults[i], adapter)
                    || (callback != address(0) && morpho.isAuthorized(callback, adapter))
            ) {
                console2.log("The adapter is still used by %s: the operator capabilities stay.", vaults[i]);
                return true;
            }
        }
        return false;
    }
}
