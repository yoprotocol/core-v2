// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal vendored subset of Chainlink CCIP's `Client` library — only the message types
///         and the latest `GenericExtraArgsV2` encoding the YO CCIP adapter needs.
/// @dev    Renamed from Chainlink's `Client` to `CcipClient` to avoid a generic name collision.
///         `extraArgs` is built off-chain by the operator and passed through verbatim, so callers
///         that want a typed builder can use `_argsToBytes`; the adapter never decodes it.
library CcipClient {
    /// @notice A token + amount leg of a CCIP message.
    struct EVMTokenAmount {
        address token;
        uint256 amount;
    }

    /// @notice CCIP message dispatched from an EVM source chain to any destination chain.
    /// @param receiver     Destination recipient, abi-encoded (an EVM address is `abi.encode`d).
    /// @param data         Arbitrary payload for a destination contract. YO sends none.
    /// @param tokenAmounts Tokens transferred with the message.
    /// @param feeToken     Fee token; `address(0)` pays the fee in the native gas token.
    /// @param extraArgs    Versioned extra arguments (see `GenericExtraArgsV2`).
    struct EVM2AnyMessage {
        bytes receiver;
        bytes data;
        EVMTokenAmount[] tokenAmounts;
        address feeToken;
        bytes extraArgs;
    }

    /// @dev Selector tag prefixing `GenericExtraArgsV2`-encoded `extraArgs`.
    bytes4 public constant GENERIC_EXTRA_ARGS_V2_TAG = 0x181dcf10;

    /// @notice Latest extra-args shape for CCIP messages.
    /// @param gasLimit                 Gas for the destination `ccipReceive`; `0` for EOA transfers.
    /// @param allowOutOfOrderExecution Whether the message may execute out of order.
    struct GenericExtraArgsV2 {
        uint256 gasLimit;
        bool allowOutOfOrderExecution;
    }

    /// @notice Encode `GenericExtraArgsV2` into the tagged `extraArgs` bytes CCIP expects.
    function _argsToBytes(GenericExtraArgsV2 memory extraArgs) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(GENERIC_EXTRA_ARGS_V2_TAG, extraArgs);
    }
}
