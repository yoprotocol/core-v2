// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal interface for Mayan's `MayanSwift` settlement contract. The YO adapter never calls
///         `MayanSwift` directly — it forwards through the Mayan Forwarder — but it decodes the
///         forwarded `protocolData` as a `createOrderWithToken` call to validate the order's
///         destination and refund owner on-chain.
/// @dev    `OrderParams` layout mirrors the verified Swift v2 contract
///         (`0xC38e4e6A15593f908255214653d3D947CA1c2338`). `destChainId` is a Wormhole chain id (NOT
///         an EVM chain id), and `destAddr` / `trader` / `tokenOut` are `bytes32` to support non-EVM
///         destinations (an EVM address is left-padded).
interface IMayanSwift {
    /// @param trader       Order owner; may cancel/refund and receives source-chain refunds.
    /// @param tokenOut     Output token on the destination chain.
    /// @param minAmountOut Minimum output amount (destination-token units).
    /// @param gasDrop      Native gas to drop to the recipient on the destination chain.
    /// @param cancelFee    Fee retained on cancellation.
    /// @param refundFee    Fee retained on refund.
    /// @param deadline     Latest fulfillment timestamp.
    /// @param destAddr     Destination-chain recipient of `tokenOut`.
    /// @param destChainId  Wormhole chain id of the destination chain.
    /// @param referrerAddr Referrer address.
    /// @param referrerBps  Referrer fee in basis points.
    /// @param auctionMode  Auction mode (`NONE` / `BYPASS` / `ENGLISH`).
    /// @param random       Salt to disambiguate otherwise-identical orders.
    struct OrderParams {
        bytes32 trader;
        bytes32 tokenOut;
        uint64 minAmountOut;
        uint64 gasDrop;
        uint64 cancelFee;
        uint64 refundFee;
        uint64 deadline;
        bytes32 destAddr;
        uint16 destChainId;
        bytes32 referrerAddr;
        uint8 referrerBps;
        uint8 auctionMode;
        bytes32 random;
    }

    /// @notice Create a Swift order funded by an ERC-20 input. Selector `0x8e8d142b`.
    function createOrderWithToken(
        address tokenIn,
        uint256 amountIn,
        OrderParams memory params
    )
        external
        returns (bytes32 orderHash);
}
