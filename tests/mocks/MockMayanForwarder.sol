// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMayanForwarder } from "src/interfaces/external/IMayanForwarder.sol";

/// @notice Minimal Mayan Forwarder stand-in. Pulls `amountIn` of `tokenIn` from the caller (the
///         adapter) and records the forwarded call so tests can assert the mayan protocol target,
///         the forwarded data, and (for the swap path) the swap parameters.
contract MockMayanForwarder is IMayanForwarder {
    using SafeERC20 for IERC20;

    struct LastCall {
        bool swap;
        address tokenIn;
        uint256 amountIn;
        address swapProtocol;
        address middleToken;
        uint256 minMiddleAmount;
        address mayanProtocol;
        bytes mayanData;
    }

    LastCall public last;
    uint256 public callCount;

    /// @inheritdoc IMayanForwarder
    function forwardERC20(
        address tokenIn,
        uint256 amountIn,
        PermitParams calldata,
        address mayanProtocol,
        bytes calldata protocolData
    )
        external
        payable
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        last.swap = false;
        last.tokenIn = tokenIn;
        last.amountIn = amountIn;
        last.swapProtocol = address(0);
        last.middleToken = address(0);
        last.minMiddleAmount = 0;
        last.mayanProtocol = mayanProtocol;
        last.mayanData = protocolData;
        ++callCount;
    }

    /// @inheritdoc IMayanForwarder
    function swapAndForwardERC20(
        address tokenIn,
        uint256 amountIn,
        PermitParams calldata,
        address swapProtocol,
        bytes calldata,
        address middleToken,
        uint256 minMiddleAmount,
        address mayanProtocol,
        bytes calldata mayanData
    )
        external
        payable
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        last.swap = true;
        last.tokenIn = tokenIn;
        last.amountIn = amountIn;
        last.swapProtocol = swapProtocol;
        last.middleToken = middleToken;
        last.minMiddleAmount = minMiddleAmount;
        last.mayanProtocol = mayanProtocol;
        last.mayanData = mayanData;
        ++callCount;
    }
}
