// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { YoChainlinkOracle } from "src/oracles/YoChainlinkOracle.sol";

import { ChainlinkOracleBase_Test } from "../ChainlinkOracleBase.t.sol";

contract SetAssetConfigIntegrationConcreteTest is ChainlinkOracleBase_Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    AUTH
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_CallerNotOwner() external {
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.eve));
        oracle.setAssetConfig(address(usdc), address(usdcFeed), 1 hours);
    }

    function test_RevertWhen_AssetZero() external whenCallerOwner {
        vm.expectRevert(YoChainlinkOracle.ZeroAsset.selector);
        oracle.setAssetConfig(address(0), address(usdcFeed), 1 hours);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  CLEAR (feed = 0)
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenFeedZero_GivenPriorEntry_ClearsAndEmits() external whenCallerOwner {
        oracle.setAssetConfig(address(usdc), address(usdcFeed), 1 hours);
        assertEq(oracle.config(address(usdc)).feed, address(usdcFeed));

        vm.expectEmit(true, true, true, true, address(oracle));
        emit YoChainlinkOracle.AssetConfigSet(address(usdc), address(0), 0);

        oracle.setAssetConfig(address(usdc), address(0), 0);
        assertEq(oracle.config(address(usdc)).feed, address(0));
    }

    function test_WhenFeedZero_GivenNoPriorEntry_NoOp() external whenCallerOwner {
        vm.expectEmit(true, true, true, true, address(oracle));
        emit YoChainlinkOracle.AssetConfigSet(address(usdc), address(0), 0);

        oracle.setAssetConfig(address(usdc), address(0), 0);
        assertEq(oracle.config(address(usdc)).feed, address(0));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    SET
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_HeartbeatZero() external whenCallerOwner {
        vm.expectRevert(YoChainlinkOracle.ZeroHeartbeat.selector);
        oracle.setAssetConfig(address(usdc), address(usdcFeed), 0);
    }

    function test_WhenValid_CachesDecimalsAndEmits() external whenCallerOwner {
        vm.expectEmit(true, true, true, true, address(oracle));
        emit YoChainlinkOracle.AssetConfigSet(address(usdc), address(usdcFeed), 1 hours);

        oracle.setAssetConfig(address(usdc), address(usdcFeed), 1 hours);

        YoChainlinkOracle.AssetConfig memory cfg = oracle.config(address(usdc));
        assertEq(cfg.feed, address(usdcFeed));
        assertEq(cfg.heartbeat, 1 hours);
        assertEq(cfg.assetDecimals, 6); // USDC
        assertEq(cfg.feedDecimals, 8); // Chainlink USD
    }
}
