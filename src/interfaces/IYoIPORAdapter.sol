// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IIPORPlasmaVault } from "./external/IIPORPlasmaVault.sol";

/// @notice Immutable adapter that brokers IPOR Fusion `PlasmaVault` interactions on behalf of a
///         vault. Handles the two legs that CAN be safely abstracted: synchronous ERC-4626
///         `deposit` and the async-redemption `claim` (`redeemFromRequest`).
/// @dev    The middle leg — `WithdrawManager.requestShares` — is intentionally NOT routed through
///         this adapter. The IPOR request slot is keyed by `msg.sender` to the WithdrawManager,
///         and a shared adapter would cause cross-YO-vault slot collisions on the same PlasmaVault.
///         YO vaults call `WithdrawManager.requestShares` directly via `YoVault.manage(...)` so
///         the request keys to the vault.
///
///         APPROVAL FLOW (per allowlisted PlasmaVault):
///           - **Deposit path**: vault approves the adapter on the *underlying token*, e.g.
///             `vault.approveToken(asset, adapter, x)`. Adapter pulls via `transferFrom`.
///           - **Claim path**: vault approves the adapter on the *share token* (the PlasmaVault is
///             itself an ERC-20), e.g. `vault.approveToken(address(plasmaVault), adapter, x)`. The
///             allowance is consumed by `_spendAllowance(vault, adapter, shares)` inside
///             `redeemFromRequest`.
///           - **Request leg (NOT via adapter)**: if the WithdrawManager's `requestFee > 0`, the
///             vault must additionally approve the WithdrawManager on the PlasmaVault share token.
///             The vault sets this via its own `approveToken`, not via the adapter.
///
///         Vault allowlist is shared with `YoERC4626Adapter` — a PlasmaVault enabled there is
///         enabled here too. Sync `withdraw` / `redeem` on a PlasmaVault remain reachable via the
///         existing `YoERC4626Adapter`; this adapter is the async-path complement.
interface IYoIPORAdapter {
    error VaultNotAllowed(IIPORPlasmaVault plasmaVault);
    error InvalidAmount();

    /// @notice Deposit `assets` of the PlasmaVault's underlying token into `plasmaVault` on behalf
    ///         of the calling vault. Mirrors `YoERC4626Adapter.deposit`.
    function deposit(IIPORPlasmaVault plasmaVault, uint256 assets) external returns (uint256 sharesReceived);

    /// @notice Finalize an async redemption against a previously-placed request, sending the
    ///         redeemed assets to the calling vault.
    /// @dev    Reverts inside `redeemFromRequest` if no request exists, the claim window has not
    ///         opened, the window has closed, or the keeper has not yet released funds.
    function claim(IIPORPlasmaVault plasmaVault, uint256 shares) external returns (uint256 assetsReceived);
}
