// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal interface for the Across Protocol `SpokePool`, the origin-chain entrypoint for
///         cross-chain intent deposits.
/// @dev    This is the latest `bytes32`-typed `deposit` entrypoint (the successor to the
///         `address`-typed `depositV3`), which encodes accounts and tokens as `bytes32` so the same
///         signature serves both EVM and non-EVM destination chains. On EVM chains an address is
///         left-padded to 32 bytes. A relayer fills the deposit on the destination chain; the
///         spread between `inputAmount` and `outputAmount` is the relayer fee.
interface IAcrossSpokePool {
    /// @notice Deposit funds for a cross-chain transfer fulfilled by an Across relayer.
    /// @param depositor            Origin-chain account credited on refund if the deposit expires.
    /// @param recipient            Destination-chain account that receives `outputToken`.
    /// @param inputToken           Token deposited on the origin chain.
    /// @param outputToken          Token delivered on the destination chain (`bytes32(0)` lets the
    ///                             relayer pick the canonical equivalent token).
    /// @param inputAmount          Amount of `inputToken` deposited.
    /// @param outputAmount         Amount of `outputToken` delivered (input minus relayer fee).
    /// @param destinationChainId   EVM chain id of the destination chain.
    /// @param exclusiveRelayer     Relayer with exclusive fill rights until `exclusivityDeadline`
    ///                             (`bytes32(0)` for none).
    /// @param quoteTimestamp       Timestamp of the fee quote this deposit was priced against.
    /// @param fillDeadline         Latest timestamp the deposit may be filled; refunded after.
    /// @param exclusivityDeadline  Timestamp until which only `exclusiveRelayer` may fill.
    /// @param message              Arbitrary calldata forwarded to the recipient if it is a contract.
    function deposit(
        bytes32 depositor,
        bytes32 recipient,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    )
        external
        payable;
}
