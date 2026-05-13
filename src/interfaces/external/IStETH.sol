// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Subset of Lido's `stETH` interface used by `YoLidoAdapter`. Inlined here so the contract
///         tree doesn't pull a full Lido dependency.
/// @dev    Source of truth: https://github.com/lidofinance/lido-dao/blob/master/contracts/0.4.24/StETH.sol
///         and `Lido.sol` for the staking entry point.
interface IStETH is IERC20 {
    /// @notice Stake ETH for stETH. Mints `getSharesByPooledEth(msg.value)` shares to `msg.sender`.
    /// @return shares Amount of shares minted (NOT stETH tokens).
    function submit(address referral) external payable returns (uint256 shares);

    /// @notice Internal share balance for `account`. Distinct from `balanceOf`, which returns the
    ///         rebasing token-denominated balance.
    function sharesOf(address account) external view returns (uint256);

    /// @notice Transfer `sharesAmount` of shares (NOT stETH tokens) from `msg.sender` to `to`.
    /// @dev    Use this instead of `transfer` for exact transfers — bypasses the 1-2 wei rounding
    ///         that arises from token↔share conversion on `transfer`.
    function transferShares(address to, uint256 sharesAmount) external returns (uint256);

    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);

    function getSharesByPooledEth(uint256 ethAmount) external view returns (uint256);
}
