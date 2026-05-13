// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/src/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Shared assertions on top of forge-std.
abstract contract Assertions is Test {
    function assertBalance(address token, address holder, uint256 expected) internal view {
        assertEq(IERC20(token).balanceOf(holder), expected, "balance");
    }

    function assertZeroBalance(address token, address holder) internal view {
        assertEq(IERC20(token).balanceOf(holder), 0, "expected zero balance");
    }

    function assertZeroAllowance(address token, address holder, address spender) internal view {
        assertEq(IERC20(token).allowance(holder, spender), 0, "expected zero allowance");
    }

    function assertCloseTo(uint256 actual, uint256 expected, uint256 tolerance) internal pure {
        uint256 diff = actual > expected ? actual - expected : expected - actual;
        require(diff <= tolerance, "assertCloseTo: diff exceeds tolerance");
    }
}
