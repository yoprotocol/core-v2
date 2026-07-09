// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Immutable adapter that brokers Across Protocol cross-chain deposits on behalf of a vault.
/// @dev    Functions are intended to be invoked exclusively via `YoVault.manage(...)` so that
///         `msg.sender == vault` inside the adapter and the origin-chain `depositor` resolves to the
///         vault (Across refunds expired deposits to `depositor`).
///
///         SAFETY: a deposit moves funds off-chain, so the destination is constrained by
///         `YoBridgeRouteRegistry` — `(vault, adapter, inputToken, destinationChainId, recipient,
///         outputToken)` must be allowlisted by the multisig (the destination token is part of the
///         route key). `message` is forced empty and `outputAmount` is floored at
///         `inputAmount * (1 - maxSlippageBps)`; the remaining operator-supplied fields (relayer,
///         deadlines) cannot redirect funds and are not floored on-chain.
///
///         APPROVAL FLOW: the vault approves the adapter on `inputToken`
///         (`vault.approveToken(inputToken, adapter, cap)`); the adapter pulls via `transferFrom`
///         and forwards to the SpokePool. ERC-20 input only — native bridging is out of scope.
interface IYoAcrossAdapter {
    error InvalidAmount();
    error RouteNotAllowed(address inputToken, uint256 destinationChainId, address recipient);
    error MessageNotAllowed();
    error SlippageTooLow(uint256 outputAmount, uint256 floor);

    /// @notice Parameters for an Across deposit. `depositor` is omitted — the adapter forces it to
    ///         the calling vault so origin-chain refunds return to the vault.
    /// @param recipient           Destination-chain recipient (allowlisted route).
    /// @param inputToken          Token deposited on the origin chain.
    /// @param outputToken         Token delivered on the destination chain
    /// @param inputAmount         Amount of `inputToken` to bridge.
    /// @param outputAmount        Amount delivered to `recipient` (input minus relayer fee).
    /// @param destinationChainId  EVM chain id of the destination chain.
    /// @param exclusiveRelayer    Relayer with exclusive fill rights (`address(0)` for none).
    /// @param quoteTimestamp      Timestamp of the fee quote.
    /// @param fillDeadline        Latest fill timestamp before refund.
    /// @param exclusivityParameter Timestamp/offset until which only `exclusiveRelayer` may fill.
    /// @param message             Calldata forwarded to a contract recipient.
    struct DepositParams {
        address recipient;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        address exclusiveRelayer;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityParameter;
        bytes message;
    }

    /// @notice Bridge `params.inputAmount` of `params.inputToken` to `params.recipient` on
    ///         `params.destinationChainId` via Across.
    /// @dev    Reverts unless the `(inputToken, destinationChainId, recipient, outputToken)` route is
    ///         allowlisted for the calling vault — the destination token is pinned by the route key.
    ///         The relayer's delivery is binding, so the adapter also floors it: `message` MUST be
    ///         empty (no destination-side hook) and `outputAmount` MUST be
    ///         `>= inputAmount * (1 - maxSlippageBps)` (caps the relayer fee; valid when `outputToken`
    ///         is `inputToken`'s same-decimal canonical equivalent, which the multisig asserts per
    ///         route). If a relayer can't fill within these terms the deposit expires and refunds to
    ///         the vault (`depositor`).
    /// @return The amount of `inputToken` bridged (`inputAmount`).
    function deposit(DepositParams calldata params) external returns (uint256);
}
