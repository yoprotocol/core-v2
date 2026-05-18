// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Common interface for immutable swap adapters that broker swaps through a single,
///         immutable aggregator address (1inch, Odos, Paraswap, KyberSwap, etc.).
/// @dev    Each aggregator gets its own implementation contract.
interface IYoSwapAdapter {
    error PairNotAllowed(address tokenIn, address tokenOut);
    error InvalidAmount();
    error SlippageTooLow(uint256 minOut, uint256 floor);
    error InsufficientOutput(uint256 received, uint256 minOut);

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        bytes calldata aggregatorCalldata
    )
        external
        returns (uint256 amountOut);
}
