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
///         FEES: paid ONLY in the native gas asset, forwarded as `msg.value` from `YoVault.manage`.
///         An ERC-20/LINK fee is not supported — this keeps the fee off the bridged token's allowance
///         and out of the vault's ERC-20 approvals.
///
///         APPROVAL FLOW: the vault approves the adapter on the bridged `token`
///         (`vault.approveToken(token, adapter, cap)`); the native fee is sent as `msg.value`.
interface IYoCcipAdapter {
    error InvalidAmount();
    error RouteNotAllowed(address token, uint64 destinationChainSelector, bytes32 recipient);
    error FeeExceedsMax(uint256 fee, uint256 maxFee);
    error IncorrectNativeFee(uint256 sent, uint256 required);
    /// @dev `recipient` has non-zero bits above 160 — it is not a left-padded EVM address, but the
    ///      CCIP message delivers to the truncated `address(uint160(...))`. Reject to fail closed.
    error RecipientNotEvmAddress(bytes32 recipient);

    /// @notice Send `amount` of `token` to `recipient` on `destinationChainSelector` via CCIP, paying
    ///         the CCIP fee in the native gas asset from `msg.value`.
    /// @dev    Reverts unless the `(token, destinationChainSelector, recipient)` route is allowlisted
    ///         for the calling vault, or if the quoted fee exceeds `maxFee`.
    /// @param destinationChainSelector CCIP chain selector of the destination chain.
    /// @param recipient                Destination recipient (allowlisted route), as `bytes32`.
    /// @param token                    Token to bridge.
    /// @param amount                   Amount of `token` to bridge.
    /// @param maxFee                   Maximum acceptable CCIP fee (in the native asset).
    /// @param extraArgs                Operator-supplied CCIP `extraArgs` (e.g. `GenericExtraArgsV2`).
    /// @return messageId The CCIP message id.
    function send(
        uint64 destinationChainSelector,
        bytes32 recipient,
        address token,
        uint256 amount,
        uint256 maxFee,
        bytes calldata extraArgs
    )
        external
        payable
        returns (bytes32 messageId);
}
