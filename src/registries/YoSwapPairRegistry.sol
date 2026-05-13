// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IYoSwapPairRegistry } from "../interfaces/IYoSwapPairRegistry.sol";

/// @title  YoSwapPairRegistry
/// @notice Per-vault allowlist of `(tokenIn, tokenOut)` pairs reachable through swap adapters.
contract YoSwapPairRegistry is Ownable2Step, IYoSwapPairRegistry {
    mapping(address vault => mapping(address tokenIn => mapping(address tokenOut => bool allowed))) private _allowed;

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) {
            revert ZeroAddress();
        }
    }

    /// @inheritdoc IYoSwapPairRegistry
    function setAllowed(address vault, address tokenIn, address tokenOut, bool allowed) external onlyOwner {
        if (vault == address(0) || tokenIn == address(0) || tokenOut == address(0)) {
            revert ZeroAddress();
        }
        if (tokenIn == tokenOut) {
            revert SameToken(tokenIn);
        }
        _allowed[vault][tokenIn][tokenOut] = allowed;
        emit PairAllowed(vault, tokenIn, tokenOut, allowed);
    }

    /// @inheritdoc IYoSwapPairRegistry
    function isAllowed(address vault, address tokenIn, address tokenOut) external view returns (bool) {
        return _allowed[vault][tokenIn][tokenOut];
    }
}
