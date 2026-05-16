// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IIPORPlasmaVault } from "src/interfaces/external/IIPORPlasmaVault.sol";

import { MockERC4626 } from "./MockERC4626.sol";
import { MockIIPORWithdrawManager } from "./MockIIPORWithdrawManager.sol";

/// @notice Mock of IPOR Fusion's `PlasmaVault`. Inherits the trivial OZ ERC-4626 plumbing from
///         `MockERC4626` and adds the async `redeemFromRequest` entry point. Eligibility is
///         delegated to the paired `MockIIPORWithdrawManager` (mutating check). Sync
///         `withdraw` / `redeem` (the OZ defaults) intentionally do NOT consult the manager — those
///         exit paths are exercised through the existing ERC-4626 adapter, not this one.
contract MockIIPORPlasmaVault is MockERC4626, IIPORPlasmaVault {
    MockIIPORWithdrawManager public immutable withdrawManager;

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        MockIIPORWithdrawManager withdrawManager_
    )
        MockERC4626(asset_, name_, symbol_)
    {
        withdrawManager = withdrawManager_;
    }

    /// @inheritdoc IIPORPlasmaVault
    function redeemFromRequest(
        uint256 shares,
        address receiver,
        address owner
    )
        external
        override
        returns (uint256 assets)
    {
        // Reverts inside the manager if the window/release conditions aren't met. Mutating: also
        // decrements the per-account slot and the global pool atomically with this check.
        withdrawManager.canWithdrawFromRequest(owner, shares);
        assets = redeem(shares, receiver, owner);
    }
}
