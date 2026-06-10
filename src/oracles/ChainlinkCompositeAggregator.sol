// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IAggregatorV3 } from "./../interfaces/external/IAggregatorV3.sol";

/// @title  ChainlinkCompositeAggregator
/// @notice Read-only Chainlink-compatible feed that composes two underlying `AggregatorV3` feeds by
///         multiplication: `price = feedMul × feedBase`, renormalized to `decimals()`.
/// @dev    Purpose: synthesize a quote that no single Chainlink feed provides on a given chain.
///         The canonical use here is **wstETH/USD on Base** — which has no direct feed — built from
///         `WSTETH/ETH (feedMul) × ETH/USD (feedBase)`. The result slots into {YoChainlinkOracle}
///         via `setAssetConfig(wstETH, thisAdapter, heartbeat)` exactly like a native feed.
///
///         Safety:
///           - Reverts (fails closed) if either leg is non-positive or its round is incomplete; the
///             consuming oracle then surfaces it as a stale/invalid price.
///           - `updatedAt` is the **older** of the two legs, so the consumer's heartbeat check
///             governs the stalest input. Set the heartbeat for the slowest leg (here WSTETH/ETH).
///           - `roundId == answeredInRound`, so consumers performing the `answeredInRound < roundId`
///             completeness check pass once the per-leg checks above have already validated freshness.
contract ChainlinkCompositeAggregator is IAggregatorV3 {
    /// @notice Feed whose value is multiplied (e.g. WSTETH/ETH).
    IAggregatorV3 public immutable feedMul;
    /// @notice Feed that rebases `feedMul` into the output unit (e.g. ETH/USD).
    IAggregatorV3 public immutable feedBase;

    uint8 private immutable _decimals;
    /// @dev `10 ** (feedMul.decimals + feedBase.decimals - decimals)`; the product is divided by this.
    uint256 private immutable _scaleDown;

    string public description;

    error ZeroFeed();
    error OutputDecimalsTooHigh(uint8 sumDecimals, uint8 outputDecimals);
    error NonPositivePrice();
    error IncompleteRound();

    /// @param _feedMul   Feed multiplied into the result (e.g. WSTETH/ETH).
    /// @param _feedBase  Feed rebasing the result into its unit (e.g. ETH/USD).
    /// @param outputDecimals Decimals this adapter reports (use 8 to match Chainlink USD feeds).
    /// @param _description Human label, e.g. "WSTETH / USD (composite)".
    constructor(IAggregatorV3 _feedMul, IAggregatorV3 _feedBase, uint8 outputDecimals, string memory _description) {
        if (address(_feedMul) == address(0) || address(_feedBase) == address(0)) {
            revert ZeroFeed();
        }
        uint8 sumDecimals = _feedMul.decimals() + _feedBase.decimals();
        if (sumDecimals < outputDecimals) {
            revert OutputDecimalsTooHigh(sumDecimals, outputDecimals);
        }
        feedMul = _feedMul;
        feedBase = _feedBase;
        _decimals = outputDecimals;
        _scaleDown = 10 ** uint256(sumDecimals - outputDecimals);
        description = _description;
    }

    /// @inheritdoc IAggregatorV3
    function decimals() external view returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IAggregatorV3
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint80 mulRound, int256 mulAnswer,, uint256 mulUpdatedAt, uint80 mulAnsweredIn) = feedMul.latestRoundData();
        (uint80 baseRound, int256 baseAnswer,, uint256 baseUpdatedAt, uint80 baseAnsweredIn) =
            feedBase.latestRoundData();

        if (mulAnswer <= 0 || baseAnswer <= 0) {
            revert NonPositivePrice();
        }
        if (mulAnsweredIn < mulRound || baseAnsweredIn < baseRound) {
            revert IncompleteRound();
        }

        answer = int256((uint256(mulAnswer) * uint256(baseAnswer)) / _scaleDown);
        updatedAt = mulUpdatedAt < baseUpdatedAt ? mulUpdatedAt : baseUpdatedAt;
        startedAt = updatedAt;
        roundId = 1;
        answeredInRound = 1;
    }
}
