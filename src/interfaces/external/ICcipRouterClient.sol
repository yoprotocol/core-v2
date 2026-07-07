// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { CcipClient } from "./CcipClient.sol";

/// @notice Minimal interface for the Chainlink CCIP `Router`, the source-chain entrypoint for
///         cross-chain token transfers and messages.
/// @dev    Quote the fee with `getFee`, approve the router for the token leg (and the fee token if
///         not native), then dispatch with `ccipSend`. A native fee is sent as `msg.value`.
interface ICcipRouterClient {
    /// @notice Quote the fee (in `message.feeToken`, or the native token if `feeToken == address(0)`)
    ///         for sending `message` to `destinationChainSelector`.
    function getFee(
        uint64 destinationChainSelector,
        CcipClient.EVM2AnyMessage memory message
    )
        external
        view
        returns (uint256 fee);

    /// @notice Dispatch `message` to `destinationChainSelector`, returning the CCIP message id.
    /// @dev    Payable: when `message.feeToken == address(0)` the fee is paid from `msg.value`.
    function ccipSend(
        uint64 destinationChainSelector,
        CcipClient.EVM2AnyMessage calldata message
    )
        external
        payable
        returns (bytes32 messageId);
}
