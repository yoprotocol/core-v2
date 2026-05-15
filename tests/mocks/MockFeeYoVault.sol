// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockERC4626 } from "./MockERC4626.sol";

/// @notice `MockYoVault` variant that reproduces the V3 YoVault redeem-fee asymmetry:
///         `requestRedeem` returns the **gross** (pre-fee) amount, but only **net** assets actually
///         reach the receiver. Used to regression-test `YoGateway`'s slippage check.
contract MockFeeYoVault is MockERC4626 {
    /// @dev Withdrawal fee in 1e18 precision (e.g. 1e17 = 10%).
    uint256 public feeBps;

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        uint256 feeBps_
    )
        MockERC4626(asset_, name_, symbol_)
    {
        feeBps = feeBps_;
    }

    /// @dev Return net (post-fee). Mirrors V3 YoVault's override.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 assets = super.previewRedeem(shares);
        return assets - (assets * feeBps) / 1e18;
    }

    /// @dev Burn shares from `owner`, transfer net assets to `receiver`, return **gross**.
    ///      Returning gross while delivering net is exactly the YoVault behavior the gateway
    ///      slippage check has to defend against.
    function requestRedeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        uint256 gross = super.previewRedeem(shares);
        uint256 fee = (gross * feeBps) / 1e18;
        uint256 net = gross - fee;
        _burn(owner, shares);
        IERC20(asset()).transfer(receiver, net);
        return gross;
    }
}
