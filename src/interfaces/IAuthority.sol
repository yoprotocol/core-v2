// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal authority interface matching solmate's `Authority` shape — the only method our
///         vaults consult during access checks.
/// @dev    Source of truth: https://github.com/transmissions11/solmate/blob/main/src/auth/Auth.sol
///         Concrete authorities (e.g., solmate's `RolesAuthority`) gate which `(role → target →
///         selector)` triples are reachable; our vault calls `canCall` to decide whether a given
///         `manage()` invocation is allowed.
interface IAuthority {
    function canCall(address user, address target, bytes4 functionSig) external view returns (bool);
}
