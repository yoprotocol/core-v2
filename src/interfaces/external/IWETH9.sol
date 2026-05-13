// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Canonical WETH9 interface — wraps ETH ↔ WETH for the Lido adapter's stake/claim flows.
/// @dev    Mainnet WETH9: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2.
interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
