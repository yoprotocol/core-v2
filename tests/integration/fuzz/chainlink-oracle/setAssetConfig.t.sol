// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoChainlinkOracle } from "src/oracles/YoChainlinkOracle.sol";

import { MockAggregatorV3 } from "../../../mocks/MockAggregatorV3.sol";
import { ChainlinkOracleBase_Test } from "../../concrete/chainlink-oracle/ChainlinkOracleBase.t.sol";

contract SetAssetConfig_ChainlinkOracle_Integration_Fuzz_Test is ChainlinkOracleBase_Test {
    /// @dev Config round-trips: stored fields equal the inputs + the cached asset/feed decimals.
    function testFuzz_SetAssetConfig_RoundTrips(uint8 feedDec, uint32 heartbeat, int256 price) external {
        // Mock aggregator stores 8 decimals by convention; vary the constructor input.
        feedDec = uint8(bound(uint256(feedDec), 0, 18));
        heartbeat = uint32(bound(uint256(heartbeat), 1, 1 days));
        // Price must be > 0 to satisfy `_price` (not exercised here but keeps the config sensible).
        price = int256(bound(uint256(price), 1, 1e18));

        MockAggregatorV3 feed = new MockAggregatorV3(feedDec);
        feed.setPrice(price);

        vm.prank(users.owner);
        oracle.setAssetConfig(address(usdc), address(feed), heartbeat);

        YoChainlinkOracle.AssetConfig memory cfg = oracle.config(address(usdc));
        assertEq(cfg.feed, address(feed));
        assertEq(cfg.heartbeat, heartbeat);
        assertEq(cfg.assetDecimals, 6, "USDC is 6 decimals");
        assertEq(cfg.feedDecimals, feedDec);
    }

    /// @dev Setting `feed = address(0)` clears the config; future quotes for that asset revert.
    function testFuzz_SetAssetConfig_ClearWipesEntry(uint32 heartbeat) external {
        heartbeat = uint32(bound(uint256(heartbeat), 1, 1 days));

        // First, set a valid config.
        vm.startPrank(users.owner);
        oracle.setAssetConfig(address(usdc), address(usdcFeed), heartbeat);

        // Then clear.
        oracle.setAssetConfig(address(usdc), address(0), 0);
        vm.stopPrank();

        YoChainlinkOracle.AssetConfig memory cfg = oracle.config(address(usdc));
        assertEq(cfg.feed, address(0), "feed cleared");
        assertEq(cfg.heartbeat, 0);
        assertEq(cfg.assetDecimals, 0);
        assertEq(cfg.feedDecimals, 0);
    }

    /// @dev `getPriceUSD` returns the 1e18-scaled price for any 8-decimal feed value.
    function testFuzz_GetPriceUSD_ScalesTo18(uint256 price) external {
        price = bound(price, 1, 1e12);
        MockAggregatorV3 feed = new MockAggregatorV3(8);
        feed.setPrice(int256(price));

        vm.prank(users.owner);
        oracle.setAssetConfig(address(usdc), address(feed), 1 hours);

        // From 8 decimals to 1e18: scale up by 1e10.
        assertEq(oracle.getPriceUSD(address(usdc)), price * 1e10);
    }
}
