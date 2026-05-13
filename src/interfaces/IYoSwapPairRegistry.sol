// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Per-vault allowlist of swap pairs reachable through swap adapters.
interface IYoSwapPairRegistry {
    event PairAllowed(address indexed vault, address indexed tokenIn, address indexed tokenOut, bool allowed);

    error ZeroAddress();
    error SameToken(address token);

    function setAllowed(address vault, address tokenIn, address tokenOut, bool allowed) external;

    function isAllowed(address vault, address tokenIn, address tokenOut) external view returns (bool);
}
