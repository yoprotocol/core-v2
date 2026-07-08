// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal interface for Mayan's `MayanSwift` settlement contract. The YO adapter never calls
///         `MayanSwift` directly — it forwards through the Mayan Forwarder — but it decodes the
///         forwarded `protocolData` as a `createOrderWithToken` call to validate the order's
///         destination and refund owner on-chain.
/// @dev    `OrderParams` layout and the `createOrderWithToken` signature mirror the verified Swift V2
///         ABI (the Mayan swap-sdk `MayanSwiftV2Artifact`, selector `0xa3a30834`), which the SDK's
///         `getSwapFromEvmTxPayload` emits. `destChainId` is a Wormhole chain id (NOT an EVM chain
///         id); `trader` / `destAddr` / `referrerAddr` / `tokenOut` are `bytes32` to support non-EVM
///         destinations (an EVM address is left-padded). Field ORDER is significant — it determines
///         the selector (`0xa3a30834`) and the decode offsets.
interface IMayanSwift {
    /// @param payloadType  Swift order/payload variant.
    /// @param trader       Order owner; may cancel/refund and receives source-chain refunds.
    /// @param destAddr     Destination-chain recipient of `tokenOut`.
    /// @param destChainId  Wormhole chain id of the destination chain.
    /// @param referrerAddr Referrer address (paid `referrerBps` of the fill).
    /// @param tokenOut     Output token on the destination chain.
    /// @param minAmountOut Minimum output amount (Mayan 8-decimal normalized units).
    /// @param gasDrop      Native gas to drop to the recipient on the destination chain.
    /// @param cancelFee    Fee retained on cancellation.
    /// @param refundFee    Fee retained on refund.
    /// @param deadline     Latest fulfillment timestamp.
    /// @param referrerBps  Referrer fee in basis points.
    /// @param auctionMode  Auction mode (`NONE` / `BYPASS` / `ENGLISH`).
    /// @param random       Salt to disambiguate otherwise-identical orders.
    struct OrderParams {
        uint8 payloadType;
        bytes32 trader;
        bytes32 destAddr;
        uint16 destChainId;
        bytes32 referrerAddr;
        bytes32 tokenOut;
        uint64 minAmountOut;
        uint64 gasDrop;
        uint64 cancelFee;
        uint64 refundFee;
        uint64 deadline;
        uint8 referrerBps;
        uint8 auctionMode;
        bytes32 random;
    }

    /// @notice Create a Swift order funded by an ERC-20 input. Selector `0xa3a30834`.
    /// @param customPayload Optional arbitrary payload delivered with the order (empty for plain
    ///                      transfers).
    function createOrderWithToken(
        address tokenIn,
        uint256 amountIn,
        OrderParams memory params,
        bytes memory customPayload
    )
        external
        returns (bytes32 orderHash);
}
