// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { Id } from "../interfaces/IMorpho.sol";
import { IYoMorphoMarketRegistry } from "../interfaces/IYoMorphoMarketRegistry.sol";

/// @title  YoMorphoMarketRegistry
/// @notice Per-vault allowlist of Morpho Blue markets reachable through `YoMorphoAdapter`.
contract YoMorphoMarketRegistry is Ownable2Step, IYoMorphoMarketRegistry {
    mapping(address vault => mapping(Id marketId => bool allowed)) private _allowed;

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) {
            revert ZeroAddress();
        }
    }

    /// @inheritdoc IYoMorphoMarketRegistry
    function setAllowed(address vault, Id marketId, bool allowed) external onlyOwner {
        if (vault == address(0)) {
            revert ZeroAddress();
        }
        _allowed[vault][marketId] = allowed;
        emit MarketAllowed(vault, marketId, allowed);
    }

    /// @inheritdoc IYoMorphoMarketRegistry
    function isAllowed(address vault, Id marketId) external view returns (bool) {
        return _allowed[vault][marketId];
    }
}
