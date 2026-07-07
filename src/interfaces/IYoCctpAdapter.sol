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
///         chain id. Operator-supplied fields that cannot redirect funds (`destinationCaller`,
///         `maxFee`, `minFinalityThreshold`) are not floored on-chain.
///
///         APPROVAL FLOW: the vault approves the adapter on USDC
///         (`vault.approveToken(usdc, adapter, cap)`); the adapter pulls via `transferFrom` and
///         forwards to the CCTP `TokenMessengerV2`.
interface IYoCctpAdapter {
    error InvalidAmount();
    error RouteNotAllowed(uint32 destinationDomain, bytes32 mintRecipient);

    /// @notice Burn `amount` USDC for minting to `mintRecipient` on `destinationDomain`.
    /// @dev    Reverts unless the `(usdc, destinationDomain, mintRecipient)` route is allowlisted for
    ///         the calling vault.
    /// @return The amount of USDC burned (`amount`).
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    )
        external
        returns (uint256);
}
