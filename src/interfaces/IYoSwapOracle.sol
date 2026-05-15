// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Asset-price oracle consumed by swap adapters to enforce on-chain slippage floors.
/// @dev    Stable interface across oracle implementations (Chainlink today; later potentially
///         Chainlink-TWAP composite, or a custom oracle). Implementations differ in how they sourced
///         prices, but they ALL expose `getQuote(in, out, amountIn) → amountOut` and fail closed on
///         stale or missing data.
interface IYoSwapOracle {
    /// @notice Thrown when either token in the pair has no oracle configuration.
    error UnknownPair(address tokenIn, address tokenOut);

    /// @notice Thrown when the underlying price source is stale or returned non-positive data.
    error StalePrice(address asset);

    /// @notice Quote `amountIn` of `tokenIn` in units of `tokenOut` at the oracle's fair price.
    /// @dev    MUST fail closed on stale or missing inputs.
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);
}
