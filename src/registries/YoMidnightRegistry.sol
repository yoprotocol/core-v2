// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IYoMidnightRegistry } from "../interfaces/IYoMidnightRegistry.sol";

/// @title  YoMidnightRegistry
/// @notice Per-vault cap on the assets that a vault has in Morpho Midnight lending through
///         `YoMidnightAdapter`. A fixed amount for each vault on each chain: a vault's
///         `totalAssets()` counts only the shares on its chain, and a deposit can raise it.
contract YoMidnightRegistry is Ownable2Step, IYoMidnightRegistry {
    mapping(address vault => uint256 assets) private _caps;

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) {
            revert ZeroAddress();
        }
    }

    /// @inheritdoc IYoMidnightRegistry
    function setCap(address vault, uint256 assets) external onlyOwner {
        if (vault == address(0)) {
            revert ZeroAddress();
        }
        _caps[vault] = assets;
        emit CapSet(vault, assets);
    }

    /// @inheritdoc IYoMidnightRegistry
    function cap(address vault) external view returns (uint256) {
        return _caps[vault];
    }
}
