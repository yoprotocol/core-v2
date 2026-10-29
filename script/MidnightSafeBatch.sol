// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { YoMidnightAdapter } from "../src/adapters/midnight/YoMidnightAdapter.sol";
import { IMidnight } from "../src/vendor/morpho-midnight/interfaces/IMidnight.sol";

import { BaseScript } from "./Base.s.sol";

/// @dev The solmate `RolesAuthority` surface that the batches use.
interface IRolesAuthorityMidnight {
    function owner() external view returns (address);
    function doesUserHaveRole(address user, uint8 role) external view returns (bool);
    function doesRoleHaveCapability(uint8 role, address target, bytes4 functionSig) external view returns (bool);
    function canCall(address user, address target, bytes4 functionSig) external view returns (bool);
    function setUserRole(address user, uint8 role, bool enabled) external;
    function setRoleCapability(uint8 role, address target, bytes4 functionSig, bool enabled) external;
}

interface IOwnable {
    function owner() external view returns (address);
}

interface IBlueBuyCallbackAuthorization {
    function setAuthorization(address authorized, bool newIsAuthorized) external;
}

interface IBlueAuthorization {
    function isAuthorized(address authorizer, address authorized) external view returns (bool);
}

/// @notice Shared parts of the admin Safe batches for a {YoMidnightAdapter}: the call list, execution as the
///         Safe on a fork, vault-owned calls under a temporary role, and the Safe Transaction Builder file.
abstract contract MidnightSafeBatch is BaseScript {
    error NotOwnedBySafe(string what, address owner, address safe);
    error TempRoleInUse(uint8 role);
    error CallFailed(uint256 index, address to, bytes returnData);
    error NotConfigured(string what);

    bytes4 internal constant MANAGE_SINGLE_SELECTOR = bytes4(keccak256("manage(address,bytes,uint256)"));

    struct Call {
        address to;
        bytes data;
    }

    /// @notice Execute `calls` as `safe`, as the Safe's MultiSend does.
    function execute(address safe, Call[] memory calls) public {
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(safe);
            (bool ok, bytes memory returnData) = calls[i].to.call(calls[i].data);
            if (!ok) {
                revert CallFailed(i, calls[i].to, returnData);
            }
        }
    }

    /// @dev Grant the Safe a temporary role for the owned targets, run the owned calls through `manage`, then
    ///      remove the capabilities and the role. The vault owner passes `requiresAuth` on `manage`; only the
    ///      target check in `manage` needs the role. Reverts when the Safe holds the role or the role already has
    ///      one of the capabilities, because the batch would remove it.
    function _appendOwned(
        Call[] memory calls,
        uint256 n,
        Call[] memory owned,
        uint256 m,
        IRolesAuthorityMidnight authority,
        address vault,
        address safe,
        uint8 tempRole
    )
        internal
        view
        returns (uint256)
    {
        if (authority.doesUserHaveRole(safe, tempRole)) {
            revert TempRoleInUse(tempRole);
        }
        for (uint256 i = 0; i < m; ++i) {
            if (authority.doesRoleHaveCapability(tempRole, owned[i].to, bytes4(owned[i].data))) {
                revert TempRoleInUse(tempRole);
            }
        }
        calls[n++] =
            Call(address(authority), abi.encodeCall(IRolesAuthorityMidnight.setUserRole, (safe, tempRole, true)));
        n = _setCapabilities(calls, n, owned, m, authority, tempRole, true);
        for (uint256 i = 0; i < m; ++i) {
            calls[n++] = Call(vault, abi.encodeWithSelector(MANAGE_SINGLE_SELECTOR, owned[i].to, owned[i].data, 0));
        }
        n = _setCapabilities(calls, n, owned, m, authority, tempRole, false);
        calls[n++] =
            Call(address(authority), abi.encodeCall(IRolesAuthorityMidnight.setUserRole, (safe, tempRole, false)));
        return n;
    }

    /// @dev One capability for each distinct owned (target, selector).
    function _setCapabilities(
        Call[] memory calls,
        uint256 n,
        Call[] memory owned,
        uint256 m,
        IRolesAuthorityMidnight authority,
        uint8 tempRole,
        bool enabled
    )
        internal
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < m; ++i) {
            bool seen;
            for (uint256 j = 0; j < i; ++j) {
                seen = seen || (owned[j].to == owned[i].to && bytes4(owned[j].data) == bytes4(owned[i].data));
            }
            if (!seen) {
                calls[n++] = Call(
                    address(authority),
                    abi.encodeCall(
                        IRolesAuthorityMidnight.setRoleCapability,
                        (tempRole, owned[i].to, bytes4(owned[i].data), enabled)
                    )
                );
            }
        }
        return n;
    }

    /// @dev Revert unless the Safe holds no temporary role and the role has none of the owned capabilities.
    function _requireTempRoleCleared(
        IRolesAuthorityMidnight authority,
        address safe,
        uint8 tempRole,
        address midnight,
        address callback
    )
        internal
        view
    {
        _require(!authority.doesUserHaveRole(safe, tempRole), "the temporary role is removed");
        _require(
            !authority.doesRoleHaveCapability(tempRole, midnight, IMidnight.setIsAuthorized.selector),
            "no Midnight capability for the temporary role"
        );
        _require(
            !authority.doesRoleHaveCapability(
                tempRole, callback, IBlueBuyCallbackAuthorization.setAuthorization.selector
            ),
            "no callback capability for the temporary role"
        );
    }

    /// @dev The first `n` calls of `buffer`, in an exact-length array.
    function _trim(Call[] memory buffer, uint256 n) internal pure returns (Call[] memory calls) {
        calls = new Call[](n);
        for (uint256 i = 0; i < n; ++i) {
            calls[i] = buffer[i];
        }
    }

    function _operatorSelectors() internal pure returns (bytes4[6] memory) {
        return [
            YoMidnightAdapter.fundCallback.selector,
            YoMidnightAdapter.defundCallback.selector,
            YoMidnightAdapter.defundCallbackAll.selector,
            YoMidnightAdapter.ratify.selector,
            YoMidnightAdapter.unratify.selector,
            YoMidnightAdapter.redeem.selector
        ];
    }

    function _requireOwner(string memory what, address owner, address safe) internal pure {
        if (owner != safe) {
            revert NotOwnedBySafe(what, owner, safe);
        }
    }

    function _require(bool condition, string memory what) internal pure {
        if (!condition) {
            revert NotConfigured(what);
        }
    }

    /// @dev Safe Transaction Builder format, as {Configure_Pool} writes it, with one transaction per call.
    function _writeBatch(string memory path, string memory name, address safe, Call[] memory calls) internal {
        // solhint-disable quotes
        string memory transactions;
        for (uint256 i = 0; i < calls.length; ++i) {
            transactions = string.concat(
                transactions,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(calls[i].to),
                '","value":"0","data":"',
                vm.toString(calls[i].data),
                '","contractMethod":null,"contractInputsValues":null}'
            );
        }
        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(chainId),
            '","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"',
            name,
            '","description":"',
            name,
            '","txBuilderVersion":"1.18.0","createdFromSafeAddress":"',
            vm.toString(safe),
            '","createdFromOwnerAddress":""},"transactions":[',
            transactions,
            "]}"
        );
        // solhint-enable quotes
        vm.createDir("script/safe-batches", true);
        vm.writeFile(path, json);
        console2.log("Wrote %s (%s transactions)", path, calls.length);
    }
}
