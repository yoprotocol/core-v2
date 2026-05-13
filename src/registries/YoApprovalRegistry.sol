// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IYoApprovalRegistry } from "../interfaces/IYoApprovalRegistry.sol";

/// @title  YoApprovalRegistry
/// @notice On-chain allowlist of `(vault, token, spender) → maxAmount` consulted by `YoVault.approveToken`.
/// @dev    Non-upgradeable by design. If a bug is discovered, deploy a new instance and re-bind every vault
///         via `YoVault.setApprovalRegistry(newRegistry)`.
contract YoApprovalRegistry is Ownable2Step, IYoApprovalRegistry {
    /// @dev `vault → token → spender → max`. Zero means "not allowlisted".
    mapping(address vault => mapping(address token => mapping(address spender => uint256 max))) private _max;

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) {
            revert ZeroAddress();
        }
    }

    /// @inheritdoc IYoApprovalRegistry
    function setApproval(address vault, address token, address spender, uint256 maxAmount) external onlyOwner {
        if (vault == address(0) || token == address(0) || spender == address(0)) {
            revert ZeroAddress();
        }
        _max[vault][token][spender] = maxAmount;
        emit ApprovalSet(vault, token, spender, maxAmount);
    }

    /// @inheritdoc IYoApprovalRegistry
    function maxApproval(address vault, address token, address spender) external view returns (uint256) {
        return _max[vault][token][spender];
    }
}
