// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Pair-quote oracle used by swap adapters to enforce on-chain slippage floors.
interface IYoSwapOracle {
    error UnknownPair(address tokenIn, address tokenOut);
    error StaleQuote(address tokenIn, address tokenOut);

    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    )
        external
        view
        returns (uint256 amountOut);
}
