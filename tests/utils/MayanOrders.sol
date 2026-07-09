// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IMayanSwift } from "src/interfaces/external/IMayanSwift.sol";

/// @notice Test helper for building Mayan Swift `createOrderWithToken` orders. Centralizes the
///         14-field `OrderParams` literal so tests don't repeat it; callers take a default plain
///         transfer and mutate individual fields for edge cases before {encode}.
library MayanOrders {
    /// @notice A valid plain-transfer order: `payloadType` 1, `ENGLISH` auction, no referrer / fees /
    ///         gas drop, deadline 1 hour out. Mutate the returned struct to exercise edge cases.
    function order(
        bytes32 trader,
        bytes32 destAddr,
        uint16 destChainId,
        address tokenOut,
        uint64 minAmountOut
    )
        internal
        view
        returns (IMayanSwift.OrderParams memory)
    {
        return IMayanSwift.OrderParams({
            payloadType: 1,
            trader: trader,
            destAddr: destAddr,
            destChainId: destChainId,
            referrerAddr: bytes32(0),
            tokenOut: bytes32(uint256(uint160(tokenOut))),
            minAmountOut: minAmountOut,
            gasDrop: 0,
            cancelFee: 0,
            refundFee: 0,
            deadline: uint64(block.timestamp + 1 hours),
            referrerBps: 0,
            auctionMode: 2,
            random: bytes32(uint256(1))
        });
    }

    /// @notice ABI-encode a `createOrderWithToken(tokenIn, amountIn, order, "")` call (no custom payload).
    function encode(
        address orderTokenIn,
        uint256 orderAmountIn,
        IMayanSwift.OrderParams memory o
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(IMayanSwift.createOrderWithToken.selector, orderTokenIn, orderAmountIn, o, "");
    }
}
