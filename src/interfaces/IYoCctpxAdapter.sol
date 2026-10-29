// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Immutable adapter that brokers Circle "CCTP for non-USDC" (CCTPx) burn-and-mint transfers
///         of one pinned token (e.g. EURC) on behalf of a vault.
/// @dev    Functions are intended to be invoked exclusively via `YoVault.manage(...)` so that
///         `msg.sender == vault` inside the adapter. The token and its CCTPx `tokenId` are pinned at
///         construction; only that token can be bridged.
///
///         SAFETY: a transfer moves funds off-chain, so the destination is constrained by
///         `YoBridgeRouteRegistry` — `(vault, adapter, token, destinationDomain, recipient)` must be
///         allowlisted by the multisig, with `recipient` keyed as `bytes32(uint256(uint160(recipient)))`
///         and `outputToken == bytes32(0)`. `destinationDomain` is a Circle domain id, NOT an EVM chain
///         id. The adapter fixes every other delivery parameter so it adds no strand vector:
///           - the destination address is the raw 20-byte `recipient` (CCTPx delivery reverts on any
///             other encoding, which would strand the burned tokens);
///           - `destinationCaller` is `bytes32(0)`, so anyone can relay the mint;
///           - no destination hook is executed;
///           - fee refunds are attributed to the vault.
///         Delivery still depends on Circle-side state: the destination TokenManager's pause, inbound
///         rate limit and minter allowance, the CCTPx denylist (recipient), the token's own pause and
///         blacklist, the service and `MessageTransmitterV2` pauses, domain trust, Iris enablement of
///         the token on the destination domain, and — for fast transfers only — the message expiry.
///         None of these consumes the message: it stays relayable once the condition clears. The multisig must
/// allowlist only EVM domains on which Iris lists the token's deployment as enabled.
///
///         RELAY: unless the signed quote includes Circle's `FORWARD` fee, Circle does not deliver the
///         message; someone must call `MessageTransmitterV2.receiveMessage` on the destination (anyone
///         can). A fast message must be relayed before its attested `expirationBlock`; after it, delivery
///         needs a finalized attestation.
///
///         `minFinalityThreshold` is restricted to the fast (`1000`) and standard
///         (`2000`) tiers; the choice between them is operator/cosigner-trusted (it is not a fund
///         destination).
///
///         FEES: paid ONLY in the native gas asset, forwarded as `msg.value` from `YoVault.manage`.
///         `msg.value` is capped at `maxNativeFee` and must equal the signed quote's total fee: the
///         adapter reverts unless the service forwards all of it (no excess kept, no shortfall covered).
///
///         APPROVAL FLOW: the vault approves the adapter on the token
///         (`vault.approveToken(token, adapter, cap)`); the adapter pulls via `transferFrom` and
///         approves the per-token CCTPx `TokenManager` for exactly the transferred amount.
interface IYoCctpxAdapter {
    error InvalidAmount();
    error InvalidRecipient();
    error InvalidFinalityThreshold(uint32 minFinalityThreshold);
    error RouteNotAllowed(uint32 destinationDomain, address recipient);
    error NativeFeeTooHigh(uint256 fee, uint256 cap);
    /// @dev `sent` is `msg.value`; `required` is the fee the service actually charged for the quote.
    error IncorrectNativeFee(uint256 sent, uint256 required);
    /// @dev Constructor: `token` is not the token CCTPx registers for `tokenId` on this chain.
    error TokenMismatch(address token, address registered);

    /// @notice Burn `amount` of the pinned token for delivery to `recipient` on `destinationDomain`,
    ///         paying the CCTPx fee in the native gas asset from `msg.value`.
    /// @dev    Reverts unless the `(token, destinationDomain, recipient)` route is allowlisted for the
    ///         calling vault, unless `minFinalityThreshold` is `1000` or `2000`, unless
    ///         `msg.value <= maxNativeFee`, and unless `msg.value` equals the signed quote's total fee.
    /// @param amount               Amount of the pinned token to transfer.
    /// @param destinationDomain    Circle domain id of the destination chain.
    /// @param recipient            Destination recipient (allowlisted route).
    /// @param minFinalityThreshold `2000` for a standard transfer, `1000` for a fast transfer.
    /// @param signedQuote          Signed fee quote from the Iris CCTPx quote API.
    /// @return The amount of the token transferred (`amount`).
    function crossChainTransfer(
        uint256 amount,
        uint32 destinationDomain,
        address recipient,
        uint32 minFinalityThreshold,
        bytes calldata signedQuote
    )
        external
        payable
        returns (uint256);
}
