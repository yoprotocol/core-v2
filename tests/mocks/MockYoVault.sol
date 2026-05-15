// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockERC4626 } from "./MockERC4626.sol";

/// @notice Minimal `IYoVault`-shaped mock for `YoGateway` tests. Standard ERC-4626 surface plus a
///         synchronous `requestRedeem` that always settles instantly and returns the asset amount.
contract MockYoVault is MockERC4626 {
    constructor(IERC20 asset_, string memory name_, string memory symbol_) MockERC4626(asset_, name_, symbol_) { }

    /// @dev Synchronous redeem matching the YoVault `requestRedeem` ABI. Always instant — returns
    ///      the asset amount delivered to `receiver`.
    function requestRedeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = redeem(shares, receiver, owner);
    }
}
