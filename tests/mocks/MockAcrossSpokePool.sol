// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal Across `SpokePool` stand-in. The adapter dispatches `deposit` via a low-level
///         call, so the mock captures it in `fallback` and reads the (fixed-offset, static) argument
///         words directly from calldata. This sidesteps the 12-argument ABI decoder, which cannot be
///         generated under the optimizer-off `lite` profile (stack too deep). It also pulls
///         `inputAmount` of `inputToken` from the caller so adapter balance/allowance assertions are
///         meaningful.
contract MockAcrossSpokePool {
    using SafeERC20 for IERC20;

    bytes32 public depositor;
    bytes32 public recipient;
    bytes32 public inputToken;
    bytes32 public outputToken;
    uint256 public inputAmount;
    uint256 public outputAmount;
    uint256 public destinationChainId;
    bytes32 public exclusiveRelayer;
    uint32 public quoteTimestamp;
    uint32 public fillDeadline;
    uint32 public exclusivityDeadline;
    bytes public message;
    bytes public lastCalldata;
    uint256 public callCount;

    /// @dev `deposit(bytes32,bytes32,bytes32,bytes32,uint256,uint256,uint256,bytes32,uint32,uint32,uint32,bytes)`.
    bytes4 internal constant DEPOSIT_SELECTOR = 0xad5425c6;

    error UnexpectedSelector(bytes4 selector);

    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        if (msg.sig != DEPOSIT_SELECTOR) {
            revert UnexpectedSelector(msg.sig);
        }

        _recordStatics();
        _recordMessage();
        lastCalldata = msg.data;

        IERC20(address(uint160(uint256(inputToken)))).safeTransferFrom(msg.sender, address(this), inputAmount);
        ++callCount;
    }

    /// @dev Record the 11 static argument words from their fixed calldata offsets (`4 + i*32`).
    ///      Read into locals, then assigned through Solidity so packed `uint32` slots stay correct.
    function _recordStatics() private {
        bytes32 dep;
        bytes32 rec;
        bytes32 inTok;
        bytes32 outTok;
        uint256 inAmt;
        uint256 outAmt;
        uint256 destId;
        bytes32 relayer;
        uint32 quoteTs;
        uint32 fillDl;
        uint32 exclDl;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            dep := calldataload(4)
            rec := calldataload(36)
            inTok := calldataload(68)
            outTok := calldataload(100)
            inAmt := calldataload(132)
            outAmt := calldataload(164)
            destId := calldataload(196)
            relayer := calldataload(228)
            quoteTs := calldataload(260)
            fillDl := calldataload(292)
            exclDl := calldataload(324)
        }
        depositor = dep;
        recipient = rec;
        inputToken = inTok;
        outputToken = outTok;
        inputAmount = inAmt;
        outputAmount = outAmt;
        destinationChainId = destId;
        exclusiveRelayer = relayer;
        quoteTimestamp = quoteTs;
        fillDeadline = fillDl;
        exclusivityDeadline = exclDl;
    }

    /// @dev Decode the dynamic `message` from its ABI offset word (word 11, byte 356) so a malformed
    ///      tail is caught by the tests rather than silently ignored.
    function _recordMessage() private {
        uint256 msgOffset;
        uint256 msgLen;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            msgOffset := calldataload(356)
            msgLen := calldataload(add(4, msgOffset))
        }
        uint256 dataStart = 4 + msgOffset + 32;
        message = msg.data[dataStart:dataStart + msgLen];
    }
}
