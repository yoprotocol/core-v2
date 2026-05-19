// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Common interface for immutable swap adapters that broker swaps through a single,
///         immutable aggregator address (1inch, Odos, Paraswap, KyberSwap, etc.).
/// @dev    Each aggregator gets its own implementation contract.
interface IYoSwapAdapter {
    /// @notice Vault-level swap audit log. Emitted on every successful `swap`.
    /// @param  vault      Calling YO vault (always `msg.sender` for `swap`).
    /// @param  aggregator The immutable aggregator address the adapter forwarded calldata to.
    /// @param  tokenIn    Token pulled from the vault.
    /// @param  tokenOut   Token returned to the vault.
    /// @param  amountIn   `tokenIn` amount pulled from the vault.
    /// @param  amountOut  `tokenOut` amount delivered to the vault (vault balance delta).
    event SwapAction(
        address indexed vault,
        address indexed aggregator,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    error PairNotAllowed(address tokenIn, address tokenOut);
    error InvalidAmount();
    error SlippageTooLow(uint256 minOut, uint256 floor);
    error InsufficientOutput(uint256 received, uint256 minOut);
    error DeadlineExpired(uint256 deadline, uint256 nowTs);

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        bytes calldata aggregatorCalldata
    )
        external
        returns (uint256 amountOut);
}
