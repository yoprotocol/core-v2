// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Shared mutable state across invariant handlers.
contract Store {
    uint256 public totalSupplied;
    uint256 public totalWithdrawn;
    uint256 public totalSwapIn;
    uint256 public totalSwapOut;

    function recordSupply(uint256 assets) external {
        totalSupplied += assets;
    }

    function recordWithdraw(uint256 assets) external {
        totalWithdrawn += assets;
    }

    function recordSwap(uint256 amountIn, uint256 amountOut) external {
        totalSwapIn += amountIn;
        totalSwapOut += amountOut;
    }
}
