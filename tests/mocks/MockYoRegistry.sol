// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoRegistry } from "src/interfaces/IYoRegistry.sol";

/// @notice Test stand-in for `YoRegistry`. The real registry requires registered addresses to be
///         live ERC-4626 contracts (it reads `asset()` for the `YoVaultAdded` event). Throughout
///         the suite many tests use bare EOAs (e.g. `users.vault`) as vault stand-ins; this mock
///         drops the `IERC4626` constraint so those tests can opt into "this address counts as a
///         registered vault" with one call.
contract MockYoRegistry is IYoRegistry {
    mapping(address vault => bool registered) private _registered;
    address[] private _vaults;

    function setVault(address vault, bool registered) external {
        if (registered && !_registered[vault]) {
            _vaults.push(vault);
        }
        _registered[vault] = registered;
    }

    /// @inheritdoc IYoRegistry
    function addYoVault(address vault) external {
        if (!_registered[vault]) {
            _vaults.push(vault);
        }
        _registered[vault] = true;
        emit YoVaultAdded(address(0), vault);
    }

    /// @inheritdoc IYoRegistry
    function removeYoVault(address vault) external {
        _registered[vault] = false;
        emit YoVaultRemoved(address(0), vault);
    }

    /// @inheritdoc IYoRegistry
    function isYoVault(address vault) external view returns (bool) {
        return _registered[vault];
    }

    /// @inheritdoc IYoRegistry
    function listYoVaults() external view returns (address[] memory) {
        return _vaults;
    }
}
