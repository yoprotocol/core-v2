// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IYoSwapAdapter } from "../../interfaces/IYoSwapAdapter.sol";
import { IYoSwapOracle } from "../../interfaces/IYoSwapOracle.sol";
import { IYoSwapPairRegistry } from "../../interfaces/IYoSwapPairRegistry.sol";

/// @title  YoSwap1inchAdapter
/// @notice Immutable swap adapter that brokers swaps through a single, immutable aggregator address.
///         Generic enough for any aggregator that pulls `tokenIn` from `msg.sender` and emits
///         `tokenOut` either to `msg.sender` or to a designated recipient encoded in the calldata.
/// @dev    Output is verified by measuring the vault's `tokenOut` balance delta against `minOut`,
///         which is itself constrained by an oracle floor. Routing inside `aggregatorCalldata`
///         is operator-supplied; correctness is enforced by post-conditions, not by decoding.
contract YoSwap1inchAdapter is ReentrancyGuard, IYoSwapAdapter {
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
        uint256 _maxSlippageBps
    ) {
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
        bytes calldata aggregatorCalldata
    )
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) {
            revert InvalidAmount();
        }
        address vault = msg.sender;

        if (!registry.isAllowed(vault, tokenIn, tokenOut)) {
            revert PairNotAllowed(tokenIn, tokenOut);
        }

        uint256 oracleQuote = oracle.getQuote(tokenIn, tokenOut, amountIn);
        uint256 floor = (oracleQuote * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        if (minOut < floor) {
            revert SlippageTooLow(minOut, floor);
        }

        IERC20 inToken = IERC20(tokenIn);
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
        if (amountOut < minOut) {
            revert InsufficientOutput(amountOut, minOut);
        }

        inToken.forceApprove(aggregator, 0);
        uint256 leftoverIn = inToken.balanceOf(address(this));
        if (leftoverIn != 0) {
            revert LeftoverInput(tokenIn, leftoverIn);
        }
        uint256 leftoverAllow = inToken.allowance(address(this), aggregator);
        if (leftoverAllow != 0) {
            revert LeftoverAllowance(tokenIn, leftoverAllow);
        }
    }
}
