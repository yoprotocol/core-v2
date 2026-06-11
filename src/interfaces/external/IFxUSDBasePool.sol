// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Subset of fx Protocol's `FxUSDBasePool` (fxSP / fxBASE) used by `YoFxSaveAdapter`. The
///         pool share is itself an ERC-20; redeeming it pays out two legs — the yield token (fxUSD)
///         and the stable token (USDC).
/// @dev    Source of truth: AladdinDAO/fx-protocol-contracts `contracts/core/FxUSDBasePool.sol`.
interface IFxUSDBasePool is IERC20 {
    /// @notice The yield token paid out on redeem (fxUSD on mainnet).
    function yieldToken() external view returns (address);

    /// @notice The stable token paid out on redeem (USDC on mainnet).
    function stableToken() external view returns (address);

    /// @notice Seconds a requested redemption stays locked before it can be claimed (≤ 7 days).
    function redeemCoolDownPeriod() external view returns (uint256);

    /// @notice Preview the two-leg payout for redeeming `amountSharesToRedeem` pool shares.
    function previewRedeem(uint256 amountSharesToRedeem)
        external
        view
        returns (uint256 amountYieldOut, uint256 amountStableOut);

    /// @notice Redeem `shares` instantly, paying an `instantRedeemFeeRatio` fee. Only the caller's
    ///         free (non-requested) balance is eligible.
    /// @param  receiver Recipient of the fxUSD + USDC payout.
    /// @return amountYieldOut  fxUSD sent to `receiver`, net of fee.
    /// @return amountStableOut USDC sent to `receiver`, net of fee.
    function instantRedeem(
        address receiver,
        uint256 shares
    )
        external
        returns (uint256 amountYieldOut, uint256 amountStableOut);
}
