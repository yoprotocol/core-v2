// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal interface for the Mayan Forwarder (`0x337685FdaB40D39bd02028545a4FfA7D287cc3E2`),
///         the unified entrypoint that pulls the input token and forwards an encoded order to a
///         whitelisted Mayan protocol (Swift / MCTP / Wormhole Swap).
interface IMayanForwarder {
    /// @notice EIP-2612 permit inputs; pass an all-zero struct to use a pre-set allowance instead.
    struct PermitParams {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Pull `amountIn` of `tokenIn` and forward `protocolData` to `mayanProtocol`.
    /// @param tokenIn       Input token pulled from the caller.
    /// @param amountIn      Amount of `tokenIn`.
    /// @param permitParams  Optional EIP-2612 permit (all-zero to skip).
    /// @param mayanProtocol Target Mayan protocol contract (must be forwarder-whitelisted).
    /// @param protocolData  ABI-encoded call executed against `mayanProtocol`.
    function forwardERC20(
        address tokenIn,
        uint256 amountIn,
        PermitParams calldata permitParams,
        address mayanProtocol,
        bytes calldata protocolData
    )
        external
        payable;

    /// @notice Swap `amountIn` of `tokenIn` to `middleToken` via `swapProtocol`, then forward
    ///         `mayanData` to `mayanProtocol` with the swap output.
    /// @param tokenIn         Input token pulled from the caller.
    /// @param amountIn        Amount of `tokenIn`.
    /// @param permitParams    Optional EIP-2612 permit (all-zero to skip).
    /// @param swapProtocol    Swap protocol contract (must be forwarder-whitelisted).
    /// @param swapData        Calldata for the swap protocol.
    /// @param middleToken     Token received from the swap and forwarded onward.
    /// @param minMiddleAmount Minimum acceptable swap output of `middleToken`.
    /// @param mayanProtocol   Target Mayan protocol contract (must be forwarder-whitelisted).
    /// @param mayanData       ABI-encoded call executed against `mayanProtocol`.
    function swapAndForwardERC20(
        address tokenIn,
        uint256 amountIn,
        PermitParams calldata permitParams,
        address swapProtocol,
        bytes calldata swapData,
        address middleToken,
        uint256 minMiddleAmount,
        address mayanProtocol,
        bytes calldata mayanData
    )
        external
        payable;
}
