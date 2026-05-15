// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal subset of Chainlink's `AggregatorV3Interface`. Inlined here so that the contract
///         tree doesn't pull a full Chainlink dependency for two methods.
/// @dev    Source of truth: chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol
///         in github.com/smartcontractkit/chainlink.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
