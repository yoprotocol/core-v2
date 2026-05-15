// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoSwapOracle } from "src/interfaces/IYoSwapOracle.sol";

import { MockAggregatorV3 } from "../../../mocks/MockAggregatorV3.sol";
import { ChainlinkOracleBase_Test } from "../../concrete/chainlink-oracle/ChainlinkOracleBase.t.sol";

contract StalePrice_ChainlinkOracle_Integration_Fuzz_Test is ChainlinkOracleBase_Test {
    /// @dev For any age relative to the configured heartbeat: age <= heartbeat → succeeds,
    ///      age > heartbeat → reverts with StalePrice.
    function testFuzz_Heartbeat_BoundaryEnforced(uint32 heartbeat, uint32 age) external {
        heartbeat = uint32(bound(uint256(heartbeat), 1, 365 days));
        age = uint32(bound(uint256(age), 0, uint256(heartbeat) * 2));

        MockAggregatorV3 feed = new MockAggregatorV3(8);
        feed.setPrice(1e8);

        vm.prank(users.owner);
        oracle.setAssetConfig(address(usdc), address(feed), heartbeat);

        // Warp forward by `heartbeat * 2` so we have room to set `updatedAt = now - age`.
        vm.warp(block.timestamp + uint256(heartbeat) * 2 + 1);
        feed.setUpdatedAt(block.timestamp - age);

        if (age > heartbeat) {
            vm.expectRevert(abi.encodeWithSelector(IYoSwapOracle.StalePrice.selector, address(usdc)));
            oracle.getPriceUSD(address(usdc));
        } else {
            uint256 price = oracle.getPriceUSD(address(usdc));
            assertEq(price, 1e18, "1.00 USD");
        }
    }

    /// @dev Forward-skewed `updatedAt > block.timestamp` must always fail closed (never underflow).
    function testFuzz_ForwardSkew_FailsClosed(uint32 heartbeat, uint32 skewSeconds) external {
        heartbeat = uint32(bound(uint256(heartbeat), 1, 365 days));
        skewSeconds = uint32(bound(uint256(skewSeconds), 1, 30 days));

        MockAggregatorV3 feed = new MockAggregatorV3(8);
        feed.setPrice(1e8);
        feed.setUpdatedAt(block.timestamp + skewSeconds);

        vm.prank(users.owner);
        oracle.setAssetConfig(address(usdc), address(feed), heartbeat);

        vm.expectRevert(abi.encodeWithSelector(IYoSwapOracle.StalePrice.selector, address(usdc)));
        oracle.getPriceUSD(address(usdc));
    }
}
