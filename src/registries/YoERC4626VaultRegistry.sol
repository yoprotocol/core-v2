// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IYoERC4626VaultRegistry } from "../interfaces/IYoERC4626VaultRegistry.sol";

/// @title  YoERC4626VaultRegistry
/// @notice Per-vault allowlist of ERC-4626 yield vaults reachable through `YoERC4626Adapter`.
contract YoERC4626VaultRegistry is Ownable2Step, IYoERC4626VaultRegistry {
    mapping(address vault => mapping(address yieldVault => bool allowed)) private _allowed;

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) {
            revert ZeroAddress();
        }
    }

    /// @inheritdoc IYoERC4626VaultRegistry
    function setAllowed(address vault, address yieldVault, bool allowed) external onlyOwner {
        if (vault == address(0) || yieldVault == address(0)) {
            revert ZeroAddress();
        }
        _allowed[vault][yieldVault] = allowed;
        emit VaultAllowed(vault, yieldVault, allowed);
    }

    /// @inheritdoc IYoERC4626VaultRegistry
    function isAllowed(address vault, address yieldVault) external view returns (bool) {
        return _allowed[vault][yieldVault];
    }
}
