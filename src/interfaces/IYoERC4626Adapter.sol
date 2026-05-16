// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Immutable adapter that brokers ERC-4626 yield-vault interactions on behalf of a vault.
/// @dev    Functions are intended to be invoked exclusively via `YoVault.manage(...)` so that
///         `msg.sender == vault` inside the adapter and the hardcoded `receiver`/`owner` arguments
///         resolve to the vault.
///
///         APPROVAL FLOW (two `approveToken` calls per yield vault you onboard):
///           - **Deposit path**: vault approves the adapter on the *underlying token*, e.g.
///             `vault.approveToken(asset, adapter, x)`. Adapter pulls via `transferFrom`.
///           - **Withdraw / withdrawAll path**: vault approves the adapter on the *share token*
///             (the yield vault is itself an ERC-20), e.g.
///             `vault.approveToken(address(yieldVault), adapter, x)`. The allowance is consumed by
///             `_spendAllowance(vault, adapter, shares)` inside `IERC4626.withdraw`/`redeem`.
///         The two approvals are independent — having one does not imply the other.
interface IYoERC4626Adapter {
    error VaultNotAllowed(IERC4626 yieldVault);
    error InvalidAmount();
    error NoPosition(IERC4626 yieldVault);

    /// @notice Deposit `assets` of the yield-vault's underlying token into `yieldVault` on behalf of
    ///         the calling vault.
    /// @dev    Requires the calling vault to have approved the adapter on the underlying token.
    function deposit(IERC4626 yieldVault, uint256 assets) external returns (uint256 sharesReceived);

    /// @notice Withdraw `assets` of the underlying token from `yieldVault` to the calling vault.
    /// @dev    Calls `yieldVault.withdraw(assets, vault, vault)`. Requires the calling vault to have
    ///         approved the adapter on the SHARE token (the yield vault itself, which is ERC-20).
    function withdraw(IERC4626 yieldVault, uint256 assets) external returns (uint256 sharesBurned);

    /// @notice Redeem the calling vault's full share position from `yieldVault`.
    /// @dev    Reads `yieldVault.balanceOf(vault)` live; cannot be spoofed by the caller. Requires
    ///         the calling vault to have approved the adapter on the SHARE token, same as
    ///         `withdraw`.
    function withdrawAll(IERC4626 yieldVault) external returns (uint256 assetsReceived);
}
