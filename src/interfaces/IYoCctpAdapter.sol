// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Immutable adapter that brokers Circle CCTP V2 native-USDC burn-and-mint transfers on
///         behalf of a vault.
/// @dev    Functions are intended to be invoked exclusively via `YoVault.manage(...)` so that
///         `msg.sender == vault` inside the adapter. The burn token is pinned to USDC at
///         construction; only USDC can be bridged.
///
///         SAFETY: a burn moves funds off-chain, so the mint destination is constrained by
///         `YoBridgeRouteRegistry` — `(vault, adapter, usdc, destinationDomain, mintRecipient)` must
///         be allowlisted by the multisig. `destinationDomain` is a Circle domain id, NOT an EVM
///         chain id. `destinationCaller` is forced to `bytes32(0)` by the adapter so the mint is
///         permissionlessly completable (no strand vector); `maxFee` is capped at `maxFeeBps` of the
///         burn amount so a bad `maxFee` cannot convert the transfer into fees. `minFinalityThreshold`
///         is operator/cosigner-trusted (it selects the fast vs. standard transfer path, not a fund
///         destination).
///
///         APPROVAL FLOW: the vault approves the adapter on USDC
///         (`vault.approveToken(usdc, adapter, cap)`); the adapter pulls via `transferFrom` and
///         forwards to the CCTP `TokenMessengerV2`.
interface IYoCctpAdapter {
    error InvalidAmount();
    error RouteNotAllowed(uint32 destinationDomain, bytes32 mintRecipient);
    error FeeTooHigh(uint256 maxFee, uint256 cap);

    /// @notice Burn `amount` USDC for minting to `mintRecipient` on `destinationDomain`.
    /// @dev    Reverts unless the `(usdc, destinationDomain, mintRecipient)` route is allowlisted for
    ///         the calling vault, and unless `maxFee <= amount * maxFeeBps / 10_000`.
    /// @return The amount of USDC burned (`amount`).
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold
    )
        external
        returns (uint256);
}
