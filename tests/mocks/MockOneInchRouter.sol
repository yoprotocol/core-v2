// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal 1inch-style aggregator stand-in. Pulls `tokenIn` from the caller, transfers a
///         deterministic amount of `tokenOut` to a chosen recipient.
contract MockOneInchRouter {
    using SafeERC20 for IERC20;

    address public tokenIn;
    address public tokenOut;
    uint256 public outputAmount;
    address public outputReceiver;
    bool public consumeAllowance = true;

    function setSwap(address _in, address _out, uint256 _outAmount, address _recipient) external {
        tokenIn = _in;
        tokenOut = _out;
        outputAmount = _outAmount;
        outputReceiver = _recipient;
    }

    function setConsumeAllowance(bool v) external {
        consumeAllowance = v;
    }

    function execute(uint256 amountIn) external {
        if (consumeAllowance) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }
        if (outputAmount > 0) {
            IERC20(tokenOut).safeTransfer(outputReceiver, outputAmount);
        }
    }

    receive() external payable { }
}
