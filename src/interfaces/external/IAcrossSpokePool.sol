// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal interface for the Across Protocol `SpokePool`, the origin-chain entrypoint for
///         cross-chain intent deposits.
/// @dev    `depositV3` is the `address`-typed EVM entrypoint; it shares the same internal
///         `_depositV3` handler as the newer `bytes32`-typed `deposit` (the universal/non-EVM
///         variant). EVM-only integrations use `depositV3` directly. A relayer fills the deposit on
///         the destination chain; the spread between `inputAmount` and `outputAmount` is the relayer
///         fee.
interface IAcrossSpokePool {
    /// @notice Deposit funds for a cross-chain transfer fulfilled by an Across relayer.
    /// @param depositor            Origin-chain account credited on refund if the deposit expires.
    /// @param recipient            Destination-chain account that receives `outputToken`.
    /// @param inputToken           Token deposited on the origin chain.
    /// @param outputToken          Token delivered on the destination chain. Must be an explicit token:
    ///                             the deployed SpokePool reverts `InvalidOutputToken()` on `address(0)`
    ///                             (the deprecated legacy `deposit` auto-resolved zero to the canonical
    ///                             equivalent; `depositV3` does not).
    /// @param inputAmount          Amount of `inputToken` deposited.
    /// @param outputAmount         Amount of `outputToken` delivered (input minus relayer fee).
    /// @param destinationChainId   EVM chain id of the destination chain.
    /// @param exclusiveRelayer     Relayer with exclusive fill rights until `exclusivityParameter`
    ///                             (`address(0)` for none).
    /// @param quoteTimestamp       Timestamp of the fee quote this deposit was priced against.
    /// @param fillDeadline         Latest timestamp the deposit may be filled; refunded after.
    /// @param exclusivityParameter Timestamp/offset until which only `exclusiveRelayer` may fill.
    /// @param message              Arbitrary calldata forwarded to the recipient if it is a contract.
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityParameter,
        bytes calldata message
    )
        external
        payable;
}
