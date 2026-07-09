// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Immutable adapter that brokers Mayan Swift cross-chain orders on behalf of a vault, via
///         the Mayan Forwarder's `forwardERC20` (bridge directly) and `swapAndForwardERC20` (swap the
///         vault's token to a middle token, then bridge).
/// @dev    Invoked exclusively via `YoVault.manage(...)` (`msg.sender == vault`). Unlike
///         Across/CCIP/CCTP, Mayan's Forwarder hides the destination inside opaque Mayan data, so the
///         adapter decodes it as a Swift `createOrderWithToken` order and enforces the destination,
///         refund-owner, and economic guards on-chain — see {YoMayanAdapter} for the full invariant
///         list. Only same-asset bridges (cbBTC→cbBTC, WETH→WETH, USDC→USDC, ...) are supported.
///
///         APPROVAL FLOW: the vault approves the adapter on `tokenIn`
///         (`vault.approveToken(tokenIn, adapter, cap)`); the adapter pulls via `transferFrom` and
///         approves the Forwarder.
interface IYoMayanAdapter {
    error InvalidAmount();
    error UnsupportedProtocolData(bytes4 selector);
    error ProtocolDataMismatch();
    error TraderNotVault(bytes32 trader);
    error ReferrerNotAllowed(bytes32 referrerAddr, uint8 referrerBps);
    error CustomPayloadNotAllowed(uint256 length);
    error InvalidPayloadType(uint8 payloadType);
    error InvalidAuctionMode(uint8 auctionMode);
    error RouteNotAllowed(address tokenIn, uint16 destChainId, bytes32 destAddr);
    error PairNotAllowed(address tokenIn, address middleToken);
    error SlippageTooLow(uint256 minMiddleAmount, uint256 floor);
    error OrderFeeTooHigh(uint256 fees, uint256 cap);
    error MinAmountOutTooLow(uint256 minAmountOut, uint256 floor);

    /// @notice Parameters for a swap-then-bridge via `swapAndForwardERC20`.
    /// @param tokenIn         Token pulled from the vault and swapped.
    /// @param amountIn        Amount of `tokenIn` to swap.
    /// @param swapProtocol    Swap protocol the Forwarder routes through (Forwarder-whitelisted).
    /// @param swapData        Calldata for the swap protocol.
    /// @param middleToken     Token received from the swap and bridged (the order's input token).
    /// @param minMiddleAmount Minimum acceptable swap output.
    /// @param mayanData       ABI-encoded Swift `createOrderWithToken` order forwarded to Swift.
    struct SwapForwardParams {
        address tokenIn;
        uint256 amountIn;
        address swapProtocol;
        bytes swapData;
        address middleToken;
        uint256 minMiddleAmount;
        bytes mayanData;
    }

    /// @notice Bridge `amountIn` of `tokenIn` directly through Swift for the calling vault.
    /// @param protocolData ABI-encoded Swift `createOrderWithToken` order. Its input token/amount
    ///                     must equal `tokenIn`/`amountIn`.
    /// @return The amount of `tokenIn` forwarded (`amountIn`).
    function forwardERC20(address tokenIn, uint256 amountIn, bytes calldata protocolData) external returns (uint256);

    /// @notice Swap the vault's `tokenIn` to `middleToken`, then bridge through Swift.
    /// @dev    The Forwarder rewrites the order's amount with the actual swap output, so only the
    ///         order's input token (`== middleToken`), refund owner, and destination are validated.
    /// @return The amount of `tokenIn` pulled from the vault (`params.amountIn`).
    function swapAndForwardERC20(SwapForwardParams calldata params) external returns (uint256);
}
