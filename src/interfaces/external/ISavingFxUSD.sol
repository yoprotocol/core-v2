// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IFxUSDBasePool } from "../external/IFxUSDBasePool.sol";

/// @notice Subset of fx Protocol's `SavingFxUSD` (fxSAVE) used by `YoFxSaveAdapter`. fxSAVE is an
///         ERC-4626 vault whose `asset()` is the `FxUSDBasePool` share, not a raw stablecoin.
/// @dev    Source of truth: AladdinDAO/fx-protocol-contracts `contracts/core/SavingFxUSD.sol`.
///
///         Two redemption modes:
///           - **Instant**: standard ERC-4626 `redeem` unwraps fxSAVE → base shares, then the
///             caller settles those via {IFxUSDBasePool-instantRedeem} (fee).
///           - **Cooldown**: `requestRedeem` burns fxSAVE and parks the backing base shares in a
///             per-`msg.sender` locked proxy that registers `FxUSDBasePool.requestRedeem`; after the
///             cooldown elapses, `claim` redeems the *entire* locked position to `receiver`
///             (fee-free). Because the locked proxy is keyed by `msg.sender`, callers that must keep
///             positions separate have to call from distinct addresses.
interface ISavingFxUSD is IERC4626 {
    /// @notice The underlying `FxUSDBasePool` whose shares back fxSAVE.
    function base() external view returns (IFxUSDBasePool);

    /// @notice Register a fee-free redemption of `shares` fxSAVE. Burns the caller's shares and
    ///         starts the base pool's cooldown against the caller's locked proxy.
    /// @return assets The amount of base-pool shares locked for the request.
    function requestRedeem(uint256 shares) external returns (uint256 assets);

    /// @notice Claim a matured redemption, sending the full fxUSD + USDC payout to `receiver`.
    /// @dev    Reverts inside the base pool if the caller's cooldown has not elapsed.
    function claim(address receiver) external;
}
