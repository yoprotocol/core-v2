// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Per-vault allowlist of ERC-4626 yield vaults reachable through `YoERC4626Adapter`.
interface IYoERC4626VaultRegistry {
    event VaultAllowed(address indexed vault, address indexed yieldVault, bool allowed);

    error ZeroAddress();

    /// @notice Allow or disallow `vault` to interact with `yieldVault` through the adapter.
    function setAllowed(address vault, address yieldVault, bool allowed) external;

    /// @notice Whether `vault` may interact with `yieldVault` through the adapter.
    function isAllowed(address vault, address yieldVault) external view returns (bool);
}
