// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Immutable adapter that brokers Mayan Swift cross-chain orders on behalf of a vault, via
///         the Mayan Forwarder's `forwardERC20` (bridge directly) and `swapAndForwardERC20` (swap the
///         vault's token to a middle token, then bridge).
/// @dev    Functions are intended to be invoked exclusively via `YoVault.manage(...)` so that
///         `msg.sender == vault` inside the adapter.
///
///         Unlike Across/CCIP/CCTP, Mayan's Forwarder hides the destination inside opaque Mayan data.
///         The adapter therefore DECODES that data as a Swift `createOrderWithToken` order and
///         enforces, on-chain and fail-closed:
///           - the order selector is exactly Swift `createOrderWithToken` (else revert);
///           - the order's input token matches what is actually bridged (`tokenIn` for the direct
///             path, `middleToken` for the swap path);
///           - the order's refund owner (`trader`) is the calling vault, so source-chain refunds
///             return to the vault;
///           - the order's `(destChainId, destAddr)` is an allowlisted route in
///             `YoBridgeRouteRegistry`, keyed on the vault's outgoing `tokenIn` (`destChainId` is a
///             Wormhole chain id).
///         `minAmountOut`, `middleToken`, `minMiddleAmount`, and the swap route stay
///         operator-supplied (cosigner-gated), as with the swap adapter's economic parameters. The
///         swap protocol is additionally gated by the Forwarder's own whitelist.
///
///         Scope: `mayanProtocol` is pinned to Swift and only `createOrderWithToken` is accepted;
///         other Mayan protocols / order functions and native-input paths are rejected by the
///         selector guard.
///
///         APPROVAL FLOW: the vault approves the adapter on `tokenIn`
///         (`vault.approveToken(tokenIn, adapter, cap)`); the adapter pulls via `transferFrom` and
///         approves the Forwarder.
interface IYoMayanAdapter {
    error InvalidAmount();
    error UnsupportedProtocolData(bytes4 selector);
    error ProtocolDataMismatch();
    error TraderNotVault(bytes32 trader);
    error RouteNotAllowed(address tokenIn, uint16 destChainId, bytes32 destAddr);

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
