// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoSwapOracle } from "src/interfaces/IYoSwapOracle.sol";
import { YoChainlinkOracle } from "src/oracles/YoChainlinkOracle.sol";

import { ChainlinkOracleBase_Test } from "../ChainlinkOracleBase.t.sol";

contract GetPriceUSDIntegrationConcreteTest is ChainlinkOracleBase_Test {
    function test_RevertGiven_AssetUnconfigured() external {
        vm.expectRevert(abi.encodeWithSelector(YoChainlinkOracle.UnknownAsset.selector, address(usdc)));
        oracle.getPriceUSD(address(usdc));
    }

    function test_RevertGiven_AnswerZero() external {
        _configure(address(usdc), address(usdcFeed), 1 hours);
        usdcFeed.setPrice(0);
        vm.expectRevert(abi.encodeWithSelector(YoChainlinkOracle.InvalidPrice.selector, address(usdc)));
        oracle.getPriceUSD(address(usdc));
    }

    function test_RevertGiven_AnswerNegative() external {
        _configure(address(usdc), address(usdcFeed), 1 hours);
        usdcFeed.setPrice(-1);
        vm.expectRevert(abi.encodeWithSelector(YoChainlinkOracle.InvalidPrice.selector, address(usdc)));
        oracle.getPriceUSD(address(usdc));
    }

    function test_GivenFresh_Returns1e18Scaled() external {
        _configure(address(usdc), address(usdcFeed), 1 hours);
        usdcFeed.setPrice(1e8);
        assertEq(oracle.getPriceUSD(address(usdc)), 1e18);

        usdcFeed.setPrice(123_456_789);
        assertEq(oracle.getPriceUSD(address(usdc)), 1_234_567_890_000_000_000);
    }

    function test_RevertGiven_Stale() external {
        _configure(address(usdc), address(usdcFeed), 1 hours);
        usdcFeed.setUpdatedAt(block.timestamp - 2 hours);
        vm.expectRevert(abi.encodeWithSelector(IYoSwapOracle.StalePrice.selector, address(usdc)));
        oracle.getPriceUSD(address(usdc));
    }

    function test_RevertGiven_UpdatedAtInFuture() external {
        _configure(address(usdc), address(usdcFeed), 1 hours);
        // Forward-skewed feed must fail closed, not underflow.
        usdcFeed.setUpdatedAt(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IYoSwapOracle.StalePrice.selector, address(usdc)));
        oracle.getPriceUSD(address(usdc));
    }
}
