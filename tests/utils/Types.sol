// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Shared user fixture for the v3 operator-safety test suite.
struct Users {
    /// @dev Multisig owner of registries, oracle, and (eventually) the vault.
    address payable owner;
    /// @dev Hot key wearing the OPERATOR role (role 99).
    address payable operator;
    /// @dev Pause-only guardian.
    address payable guardian;
    /// @dev Stand-in vault address used by registry/adapter unit tests.
    address payable vault;
    /// @dev Generic attacker / unauthorized caller.
    address payable eve;
    /// @dev Depositor stand-in used by `YoVault` end-user tests.
    address payable alice;
    /// @dev Second party / fee recipient used by `YoVault` end-user tests.
    address payable bob;
}
