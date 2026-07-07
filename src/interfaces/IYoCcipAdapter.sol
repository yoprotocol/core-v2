// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Immutable adapter that brokers Chainlink CCIP token transfers on behalf of a vault.
/// @dev    Functions are intended to be invoked exclusively via `YoVault.manage(...)` so that
///         `msg.sender == vault` inside the adapter. Token transfers only — the CCIP message
///         payload is forced empty, so vault funds can never trigger an arbitrary cross-chain call.
///
///         SAFETY: a send moves funds off-chain, so the destination is constrained by
///         `YoBridgeRouteRegistry` — `(vault, adapter, token, destinationChainSelector, recipient)`
///         must be allowlisted by the multisig. `destinationChainSelector` is the CCIP-specific
///         chain id. The quoted fee is capped at the operator's `maxFee`.
///
///         APPROVAL FLOW: the vault approves the adapter on the bridged `token`
///         (`vault.approveToken(token, adapter, cap)`). For a LINK/ERC-20 fee, the vault also
///         approves the adapter on `feeToken`. For a native fee (`feeToken == address(0)`), the fee
///         is forwarded as `msg.value` from `YoVault.manage`.
interface IYoCcipAdapter {
    error InvalidAmount();
    error RouteNotAllowed(address token, uint64 destinationChainSelector, bytes32 recipient);
    error FeeExceedsMax(uint256 fee, uint256 maxFee);
    error IncorrectNativeFee(uint256 sent, uint256 required);

    /// @notice Send `amount` of `token` to `recipient` on `destinationChainSelector` via CCIP.
    /// @dev    Reverts unless the `(token, destinationChainSelector, recipient)` route is allowlisted
    ///         for the calling vault, or if the quoted fee exceeds `maxFee`.
    /// @param destinationChainSelector CCIP chain selector of the destination chain.
    /// @param recipient                Destination recipient (allowlisted route), as `bytes32`.
    /// @param token                    Token to bridge.
    /// @param amount                   Amount of `token` to bridge.
    /// @param feeToken                 Fee token; `address(0)` pays the fee from `msg.value`. May
    ///                                 equal `token`.
    /// @param maxFee                   Maximum acceptable CCIP fee.
    /// @param extraArgs                Operator-supplied CCIP `extraArgs` (e.g. `GenericExtraArgsV2`).
    /// @return messageId The CCIP message id.
    function send(
        uint64 destinationChainSelector,
        bytes32 recipient,
        address token,
        uint256 amount,
        address feeToken,
        uint256 maxFee,
        bytes calldata extraArgs
    )
        external
        payable
        returns (bytes32 messageId);
}
