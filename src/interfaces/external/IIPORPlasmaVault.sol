// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Minimal interface for IPOR Fusion's `PlasmaVault` — a standard ERC-4626 share with an
///         additional async-redemption entry point.
/// @dev    Deposits are pure ERC-4626. Sync `withdraw` / `redeem` exist but route through the
///         vault's `WithdrawManager.canWithdrawFromUnallocated` which reserves liquidity for
///         already-released scheduled withdrawals; they revert when the vault is illiquid. The
///         async path is the canonical exit:
///           1. Holder calls `WithdrawManager.requestShares(shares)`. The request is keyed by
///              `msg.sender` in a one-slot mapping; calling again overwrites.
///           2. IPOR keeper calls `WithdrawManager.releaseFunds(...)` off-band.
///           3. Holder (or anyone with share allowance from the holder) calls
///              `redeemFromRequest(shares, receiver, owner)` within the claim window.
///
///         `redeemFromRequest` is fee-free; the sync withdraw path is not. NAV at finalize, not at
///         request time — users absorb P&L between the two calls.
interface IIPORPlasmaVault is IERC4626 {
    /// @notice Redeem shares against a pending request placed via `WithdrawManager.requestShares`.
    /// @dev    Standard ERC-4626 allowance semantics — `msg.sender` must be `owner` or hold share
    ///         allowance from `owner`. Reverts outside the claim window or before the keeper has
    ///         released funds covering the request.
    function redeemFromRequest(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
