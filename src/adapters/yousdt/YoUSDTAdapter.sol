// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  YoUSDTAdapter
/// @notice Pulls USDT from the caller and forwards it to the yoUSDT vault in a single tx.
/// @dev    Caller must approve USDT to this contract first.
///         USDT is non-standard (no return value); SafeERC20 is required.
contract YoUSDTAdapter {
    using SafeERC20 for IERC20;

    IERC20 public constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    address public constant VAULT = 0xb9a7da9e90D3B428083BAe04b860faA6325b721e;

    /// @notice Transfer `amount` USDT from msg.sender to the yoUSDT vault.
    function transfer(uint256 amount) external {
        USDT.safeTransferFrom(msg.sender, VAULT, amount);
    }

    /// @notice Sweep this contract's full balance of `token` into the vault.
    /// @dev    Permissionless: rescued funds always go to VAULT, so no auth is needed.
    function rescue(IERC20 token) external {
        token.safeTransfer(VAULT, token.balanceOf(address(this)));
    }
}
