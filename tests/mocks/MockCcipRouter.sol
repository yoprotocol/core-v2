// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CcipClient } from "src/interfaces/external/CcipClient.sol";
import { ICcipRouterClient } from "src/interfaces/external/ICcipRouterClient.sol";

/// @notice Minimal CCIP `Router` stand-in. Returns a configurable fee from `getFee`, pulls the token
///         leg (and an ERC-20 fee) from the caller (the adapter) on `ccipSend`, and records the last
///         message so tests can assert forwarded parameters and fee accounting.
contract MockCcipRouter is ICcipRouterClient {
    using SafeERC20 for IERC20;

    error InsufficientNativeFee(uint256 sent, uint256 required);

    uint256 public fee;
    bytes32 public nextMessageId = keccak256("CCIP_MESSAGE_ID");

    struct LastSend {
        uint64 destinationChainSelector;
        bytes receiver;
        bytes data;
        address token;
        uint256 amount;
        address feeToken;
        bytes extraArgs;
        uint256 nativeValue;
    }

    LastSend public last;
    uint256 public callCount;

    function setFee(uint256 newFee) external {
        fee = newFee;
    }

    /// @inheritdoc ICcipRouterClient
    function getFee(uint64, CcipClient.EVM2AnyMessage memory) external view returns (uint256) {
        return fee;
    }

    /// @inheritdoc ICcipRouterClient
    function ccipSend(
        uint64 destinationChainSelector,
        CcipClient.EVM2AnyMessage calldata message
    )
        external
        payable
        returns (bytes32 messageId)
    {
        CcipClient.EVMTokenAmount calldata leg = message.tokenAmounts[0];
        IERC20(leg.token).safeTransferFrom(msg.sender, address(this), leg.amount);

        if (message.feeToken == address(0)) {
            if (msg.value < fee) {
                revert InsufficientNativeFee(msg.value, fee);
            }
        } else {
            IERC20(message.feeToken).safeTransferFrom(msg.sender, address(this), fee);
        }

        last = LastSend({
            destinationChainSelector: destinationChainSelector,
            receiver: message.receiver,
            data: message.data,
            token: leg.token,
            amount: leg.amount,
            feeToken: message.feeToken,
            extraArgs: message.extraArgs,
            nativeValue: msg.value
        });
        ++callCount;

        return nextMessageId;
    }
}
