// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IAggregatorV3 } from "src/interfaces/external/IAggregatorV3.sol";

/// @notice Minimal Chainlink aggregator stand-in with manual price + freshness controls.
contract MockAggregatorV3 is IAggregatorV3 {
    uint8 private immutable _decimals;
    int256 public price;
    uint256 public updatedAt;
    uint80 public roundId;
    /// @dev When zero, `latestRoundData` mirrors `roundId` (the standard Chainlink behavior). When
    ///      non-zero, the explicit value is returned — used to simulate unanswered rounds where
    ///      `answeredInRound < roundId`.
    uint80 public answeredInRoundOverride;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
        updatedAt = block.timestamp;
        roundId = 1;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
        roundId++;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    /// @notice Force a specific `answeredInRound` value distinct from `roundId`. Pass 0 to revert
    ///         to the default (mirror `roundId`).
    function setAnsweredInRound(uint80 _answeredInRound) external {
        answeredInRoundOverride = _answeredInRound;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint80 answeredInRound = answeredInRoundOverride == 0 ? roundId : answeredInRoundOverride;
        return (roundId, price, updatedAt, updatedAt, answeredInRound);
    }
}
