// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IYoSwapPairRegistry } from "../interfaces/IYoSwapPairRegistry.sol";

/// @title  YoSwapPairRegistry
/// @notice Per-vault allowlist of `(tokenIn, tokenOut)` pairs reachable through swap adapters.
///         Each pair has a `PairMode` controlling what on-chain checks the adapter applies.
/// @dev    Direction matters: `(A, B)` does not imply `(B, A)`. Add both entries explicitly if
///         the vault should be able to swap in both directions.
contract YoSwapPairRegistry is Ownable2Step, IYoSwapPairRegistry {
    mapping(address vault => mapping(address tokenIn => mapping(address tokenOut => PairMode))) private _modes;

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) {
            revert ZeroAddress();
        }
    }

    /// @inheritdoc IYoSwapPairRegistry
    function setMode(address vault, address tokenIn, address tokenOut, PairMode mode) external onlyOwner {
        if (vault == address(0) || tokenIn == address(0) || tokenOut == address(0)) {
            revert ZeroAddress();
        }
        if (tokenIn == tokenOut) {
            revert SameToken(tokenIn);
        }
        _modes[vault][tokenIn][tokenOut] = mode;
        emit PairModeSet(vault, tokenIn, tokenOut, mode);
    }

    /// @inheritdoc IYoSwapPairRegistry
    function modeOf(address vault, address tokenIn, address tokenOut) external view returns (PairMode) {
        return _modes[vault][tokenIn][tokenOut];
    }

    /// @inheritdoc IYoSwapPairRegistry
    function isAllowed(address vault, address tokenIn, address tokenOut) external view returns (bool) {
        return _modes[vault][tokenIn][tokenOut] != PairMode.DISALLOWED;
    }
}
