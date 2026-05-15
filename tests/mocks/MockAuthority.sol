// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IAuthority } from "src/interfaces/IAuthority.sol";

/// @notice Test authority with a per-`(user, target, selector)` allowlist. Production uses
///         solmate's `RolesAuthority`; this mock skips the role indirection for direct control.
contract MockAuthority is IAuthority {
    mapping(address user => mapping(address target => mapping(bytes4 sig => bool))) private _allowed;

    function setAllowed(address user, address target, bytes4 sig, bool allowed) external {
        _allowed[user][target][sig] = allowed;
    }

    function canCall(address user, address target, bytes4 functionSig) external view returns (bool) {
        return _allowed[user][target][functionSig];
    }
}
