// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoChainlinkOracle } from "src/oracles/YoChainlinkOracle.sol";

import { MockAggregatorV3 } from "../../../mocks/MockAggregatorV3.sol";
import { Integration_Test } from "../../Integration.t.sol";

/// @notice Shared base for `YoChainlinkOracle` BTT tests. Deploys the oracle and a default USDC
///         feed, and provides a state-changing helper so each function-level test file can focus
///         on assertions.
abstract contract ChainlinkOracleBase_Test is Integration_Test {
    YoChainlinkOracle internal oracle;
    MockAggregatorV3 internal usdcFeed;

    function setUp() public virtual override {
        super.setUp();
        oracle = new YoChainlinkOracle(users.owner);
        usdcFeed = new MockAggregatorV3(8);
        usdcFeed.setPrice(1e8); // 1.00 USD
    }

    function _configure(address asset, address feed, uint32 heartbeat) internal {
        vm.prank(users.owner);
        oracle.setAssetConfig(asset, feed, heartbeat);
    }

    /// @dev Convenience: deploy a fresh 8-decimal aggregator at `price` and configure the asset.
    function _configureWithPrice(address asset, int256 price) internal returns (MockAggregatorV3 feed) {
        feed = new MockAggregatorV3(8);
        feed.setPrice(price);
        _configure(asset, address(feed), 1 hours);
    }
}
