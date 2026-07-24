// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IYoMidnightMarketRegistry } from "../interfaces/IYoMidnightMarketRegistry.sol";

/// @title  YoMidnightMarketRegistry
/// @notice Per-vault allowlist of Morpho Midnight markets reachable through `YoMidnightAdapter`, each
///         carrying a sell-side `minTick` price floor set by the owner when the market is enabled.
contract YoMidnightMarketRegistry is Ownable2Step, IYoMidnightMarketRegistry {
    /// @param allowed Whether the vault may reach this market through the adapter.
    /// @param minTick Lowest offer tick the adapter will ratify (sell offers) or fill (`takeSell`).
    struct MarketPolicy {
        bool allowed;
        uint32 minTick;
    }

    mapping(address vault => mapping(bytes32 marketId => MarketPolicy policy)) private _policy;

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) {
            revert ZeroAddress();
        }
    }

    /// @inheritdoc IYoMidnightMarketRegistry
    function setAllowed(address vault, bytes32 marketId, bool allowed, uint32 minTick) external onlyOwner {
        if (vault == address(0)) {
            revert ZeroAddress();
        }
        _policy[vault][marketId] = MarketPolicy({ allowed: allowed, minTick: minTick });
        emit MarketAllowed(vault, marketId, allowed, minTick);
    }

    /// @inheritdoc IYoMidnightMarketRegistry
    function isAllowed(address vault, bytes32 marketId) external view returns (bool) {
        return _policy[vault][marketId].allowed;
    }

    /// @inheritdoc IYoMidnightMarketRegistry
    function minTickOf(address vault, bytes32 marketId) external view returns (uint32) {
        return _policy[vault][marketId].minTick;
    }
}
