// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IYoSwapOracle } from "../interfaces/IYoSwapOracle.sol";

/// @title  YoSwapOracle
/// @notice Pair-quote oracle used by swap adapters to enforce on-chain slippage floors.
/// @dev    SCAFFOLD ONLY: production must wire `getQuote` to a real source. Until then, every pair
///         reverts with `UnknownPair`/`StaleQuote` so adapters fail closed.
contract YoSwapOracle is Ownable2Step, IYoSwapOracle {
    struct QuoteSource {
        address source;
        uint8 kind;
        uint32 heartbeat;
    }

    event QuoteSourceSet(address indexed tokenIn, address indexed tokenOut, QuoteSource source);

    mapping(address tokenIn => mapping(address tokenOut => QuoteSource source)) private _sources;

    constructor(address initialOwner) Ownable(initialOwner) { }

    function setQuoteSource(address tokenIn, address tokenOut, QuoteSource calldata src) external onlyOwner {
        _sources[tokenIn][tokenOut] = src;
        emit QuoteSourceSet(tokenIn, tokenOut, src);
    }

    /// @inheritdoc IYoSwapOracle
    /// @dev TODO: implement per-`kind` dispatch (Chainlink / UniV3 TWAP / Pyth / etc).
    function getQuote(address tokenIn, address tokenOut, uint256 /* amountIn */ )
        external
        view
        returns (uint256 amountOut)
    {
        QuoteSource memory src = _sources[tokenIn][tokenOut];
        if (src.kind == 0) {
            revert UnknownPair(tokenIn, tokenOut);
        }
        revert StaleQuote(tokenIn, tokenOut);
    }

    function quoteSource(address tokenIn, address tokenOut) external view returns (QuoteSource memory) {
        return _sources[tokenIn][tokenOut];
    }
}
