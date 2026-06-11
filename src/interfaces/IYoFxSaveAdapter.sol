// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Immutable adapter that brokers fxSAVE (`SavingFxUSD`) redemptions on behalf of a vault.
///         Deposits are out of scope — they are handled upstream by the swap adapter.
/// @dev    Functions are intended to be invoked exclusively via `YoVault.manage(...)` so that
///         `msg.sender == vault` inside the adapter and every payout resolves to the vault. Both
///         redemption modes pay out two tokens: fxUSD (yield leg) and USDC (stable leg).
///
///         APPROVALS REQUIRED (set per-vault by the multisig at onboarding time):
///           - **Redeem (instant + request)**: vault approves the adapter on fxSAVE shares via
///             `approveToken(fxSave, adapter, cap)`. One approval covers both entrypoints — the
///             adapter pulls shares to itself for `instantRedeem` and to the vault's redeemer for
///             `requestRedeem`.
///           - **Claim**: no approval; the payout flows fxSAVE → vault directly.
///
///         COOLDOWN FLOW: redemption without fee is two-step. `requestRedeem` burns fxSAVE shares
///         and locks the backing position behind a per-vault {YoFxSaveRedeemer}; after the base
///         pool's cooldown elapses (≤ 7 days), the vault calls `claim` to receive fxUSD + USDC.
///         Each vault gets its own redeemer, so concurrent vault positions never commingle.
///
///         INSTANT FLOW: `instantRedeem` settles in one call but pays the base pool's
///         `instantRedeemFeeRatio`. It only consumes the vault's free (non-requested) shares.
interface IYoFxSaveAdapter {
    error InvalidAmount();
    error NoPosition();

    /// @notice Instantly redeem `shares` of fxSAVE for the calling vault, paying the protocol fee.
    /// @dev    Unwraps fxSAVE → base shares to the adapter, then settles via the base pool with the
    ///         vault as receiver. Requires the vault to have approved the adapter on fxSAVE shares.
    /// @return fxUsdOut fxUSD forwarded to the vault, net of fee.
    /// @return usdcOut  USDC forwarded to the vault, net of fee.
    function instantRedeem(uint256 shares) external returns (uint256 fxUsdOut, uint256 usdcOut);

    /// @notice Queue a fee-free redemption of `shares` of fxSAVE for the calling vault.
    /// @dev    Burns the shares and starts the cooldown against the vault's dedicated redeemer
    ///         (deployed deterministically on first use). Requires the vault to have approved the
    ///         adapter on fxSAVE shares. Calling again before `claim` accumulates the request AND
    ///         resets the cooldown timer.
    /// @return assets The amount of base-pool shares locked for the request.
    function requestRedeem(uint256 shares) external returns (uint256 assets);

    /// @notice Claim the calling vault's matured redemption, forwarding fxUSD + USDC to the vault.
    /// @dev    Redeems the vault's *entire* locked position (the base pool has no partial claim).
    ///         Reverts with `NoPosition` if the vault never requested, or propagates the base pool's
    ///         lock error if the cooldown has not elapsed.
    /// @return fxUsdOut fxUSD forwarded to the vault.
    /// @return usdcOut  USDC forwarded to the vault.
    function claim() external returns (uint256 fxUsdOut, uint256 usdcOut);

    /// @notice The deterministic redeemer address for `vault` (deployed on first `requestRedeem`).
    function redeemerOf(address vault) external view returns (address);
}
