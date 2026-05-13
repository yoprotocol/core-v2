// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoSwapOracle } from "src/interfaces/IYoSwapOracle.sol";

/// @notice Test double that returns canned quotes per pair, with optional revert mode.
contract MockSwapOracle is IYoSwapOracle {
    /// @dev `quote` is the price for `1` unit of `tokenIn` in `tokenOut` decimals, scaled by `1e18`
    ///      to simplify the test math. amountOut = amountIn * quote / 1e18.
    mapping(address tokenIn => mapping(address tokenOut => uint256 quote)) private _q;
    mapping(address tokenIn => mapping(address tokenOut => bool stale)) private _stale;
    mapping(address tokenIn => mapping(address tokenOut => bool unknown)) private _unknown;

    function setQuote(address tokenIn, address tokenOut, uint256 q) external {
        _q[tokenIn][tokenOut] = q;
    }

    function setStale(address tokenIn, address tokenOut, bool v) external {
        _stale[tokenIn][tokenOut] = v;
    }

    function setUnknown(address tokenIn, address tokenOut, bool v) external {
        _unknown[tokenIn][tokenOut] = v;
    }

    function getQuote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256) {
        if (_unknown[tokenIn][tokenOut]) {
            revert UnknownPair(tokenIn, tokenOut);
        }
        if (_stale[tokenIn][tokenOut]) {
            revert StaleQuote(tokenIn, tokenOut);
        }
        return (amountIn * _q[tokenIn][tokenOut]) / 1e18;
    }
}
