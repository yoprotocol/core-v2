// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IYoRegistry } from "./../../interfaces/IYoRegistry.sol";
import { IYoSwapAdapter } from "./../../interfaces/IYoSwapAdapter.sol";
import { IYoSwapOracle } from "./../../interfaces/IYoSwapOracle.sol";
import { IYoSwapPairRegistry } from "./../../interfaces/IYoSwapPairRegistry.sol";
import { YoAdapterBase } from "./../base/YoAdapterBase.sol";

/// @title  YoSwapAdapter
/// @notice Generic immutable swap adapter for **synchronous, approve-based aggregators**: 1inch v5/v6,
///         Odos, Paraswap, KyberSwap, OpenOcean, and any other aggregator that consumes `tokenIn` via
///         `transferFrom` after being approved, and emits `tokenOut` synchronously in the same tx.
/// @dev    Output is verified by measuring the vault's `tokenOut` balance delta against `minOut`,
///         which is itself constrained by an oracle floor. Routing inside `aggregatorCalldata` is
///         operator-supplied; correctness is enforced by post-conditions, not by decoding.
///
///         NOT suitable for:
///           - Permit2-based flows (UniswapX, some 0x paths) — they do not pull via `transferFrom`.
///           - Intent-based / async settlement (CoWswap, UniswapX, 1inch Fusion) — settlement
///             happens in a later transaction so the same-tx balance-delta check cannot fire.
///         Those venues need sibling adapters (`YoSwapCowAdapter`, etc.) that share `IYoSwapAdapter`.
///
///         Deploy one instance per target aggregator. The aggregator address lives in deployment
///         metadata / the operations runbook, not in the contract name.
contract YoSwapAdapter is YoAdapterBase, IYoSwapAdapter {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    address public immutable aggregator;
    IYoSwapOracle public immutable oracle;
    IYoSwapPairRegistry public immutable registry;
    uint256 public immutable maxSlippageBps;

    constructor(
        address _aggregator,
        IYoSwapOracle _oracle,
        IYoSwapPairRegistry _registry,
        uint256 _maxSlippageBps,
        IYoRegistry _yoRegistry
    )
        YoAdapterBase(_yoRegistry)
    {
        aggregator = _aggregator;
        oracle = _oracle;
        registry = _registry;
        maxSlippageBps = _maxSlippageBps;
    }

    /// @inheritdoc IYoSwapAdapter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        bytes calldata aggregatorCalldata
    )
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) {
            revert DeadlineExpired(deadline, block.timestamp);
        }
        if (amountIn == 0) {
            revert InvalidAmount();
        }
        address vault = msg.sender;

        IYoSwapPairRegistry.PairMode mode = registry.modeOf(vault, tokenIn, tokenOut);
        if (mode == IYoSwapPairRegistry.PairMode.DISALLOWED) {
            revert PairNotAllowed(tokenIn, tokenOut);
        }

        // ORACLE_CHECKED: enforce on-chain slippage floor.
        // OPERATOR_TRUSTED: skip the oracle entirely; `minOut` is the only on-chain constraint and
        // the cosigner is the sole defense against sandwich attacks. Use for exotic assets the
        // multisig has explicitly opted into.
        if (mode == IYoSwapPairRegistry.PairMode.ORACLE_CHECKED) {
            uint256 oracleQuote = oracle.getQuote(tokenIn, tokenOut, amountIn);
            uint256 floor = (oracleQuote * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
            if (minOut < floor) {
                revert SlippageTooLow(minOut, floor);
            }
        }

        IERC20 inToken = IERC20(tokenIn);
        {
            IERC20 outToken = IERC20(tokenOut);
            uint256 vaultOutBefore = outToken.balanceOf(vault);

            inToken.safeTransferFrom(vault, address(this), amountIn);
            inToken.forceApprove(aggregator, amountIn);

            aggregator.functionCall(aggregatorCalldata);

            uint256 adapterOut = outToken.balanceOf(address(this));
            if (adapterOut > 0) {
                outToken.safeTransfer(vault, adapterOut);
            }

            amountOut = outToken.balanceOf(vault) - vaultOutBefore;
        }
        if (amountOut < minOut) {
            revert InsufficientOutput(amountOut, minOut);
        }

        inToken.forceApprove(aggregator, 0);

        emit SwapAction(vault, aggregator, tokenIn, tokenOut, amountIn, amountOut);
    }
}
