// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Immutable adapter that brokers Lido stETH stake / unstake / claim on behalf of a vault.
/// @dev    Functions are intended to be invoked exclusively via `YoVault.manage(...)` so that
///         `msg.sender == vault` inside the adapter and the hardcoded `receiver` / `owner`
///         arguments resolve to the vault.
///
///         APPROVALS REQUIRED (set per-vault by the multisig at onboarding time):
///           - **Stake**:     vault approves adapter on WETH (via `approveToken`).
///           - **Unstake req**: vault approves adapter on stETH (via `approveToken`).
///           - **Claim**:     vault approves adapter for the WithdrawalQueue ERC-721 via
///             `setApprovalForAll(adapter, true)`. The multisig does this once at setup; there is no
///             `approveToken` analogue for ERC-721 in this codebase.
///
///         ASYNC FLOW: unstake is two-step. `requestUnstake` mints an NFT to the vault; the request
///         settles after Lido's withdrawal queue finalizes (typically 1-4 days on mainnet). The
///         vault then calls `claimUnstake(requestId)` to redeem ETH (returned to the vault as WETH).
interface IYoLidoAdapter {
    error InvalidAmount();
    error NoTransfer();
    error NoShareDelta();
    error UnexpectedETH(address sender);

    /// @notice Stake `wethAmount` of WETH for stETH on behalf of the calling vault.
    /// @dev    Adapter unwraps WETH → ETH → `Lido.submit` and forwards minted stETH to the vault.
    function stake(uint256 wethAmount) external returns (uint256 stETHReceived);

    /// @notice Queue an unstake of `stETHAmount` of stETH. The NFT receipt is minted directly to
    ///         the calling vault.
    /// @dev    `stETHAmount` must satisfy Lido's queue bounds (currently 100 wei ≤ x ≤ 1000 ether).
    function requestUnstake(uint256 stETHAmount) external returns (uint256 requestId);

    /// @notice Claim a finalized unstake. Adapter pulls the NFT from the calling vault, redeems
    ///         it for ETH, wraps to WETH, and forwards the WETH to the vault.
    /// @dev    Caller (the vault) MUST have called `WithdrawalQueue.setApprovalForAll(adapter, true)`
    ///         at onboarding time.
    function claimUnstake(uint256 requestId) external returns (uint256 wethReceived);
}
