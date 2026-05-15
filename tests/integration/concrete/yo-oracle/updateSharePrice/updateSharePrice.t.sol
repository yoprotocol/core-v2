// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoOracle } from "src/interfaces/IYoOracle.sol";

import { YoOracleBase_Test } from "../YoOracleBase.t.sol";

contract UpdateSharePriceIntegrationConcreteTest is YoOracleBase_Test {
    function test_RevertWhen_CallerNotUpdater() external {
        vm.prank(users.eve);
        vm.expectRevert(IYoOracle.NotUpdater.selector);
        oracle.updateSharePrice(users.vault, 1e18);
    }

    function test_WhenFirstUpdate_SetsLatestAndAnchor() external {
        uint256 price = 1e18;

        vm.expectEmit(true, true, true, false, address(oracle));
        emit IYoOracle.SharePriceUpdated(users.vault, price, uint64(block.timestamp));

        vm.prank(users.operator);
        oracle.updateSharePrice(users.vault, price);

        (uint256 latestPrice, uint64 latestTs) = oracle.getLatestPrice(users.vault);
        (uint256 anchorPrice, uint64 anchorTs) = oracle.getAnchor(users.vault);
        assertEq(latestPrice, price);
        assertEq(anchorPrice, price);
        assertEq(latestTs, anchorTs);
    }

    function test_WhenWithinDefaultLimit_UpdatesLatest() external {
        uint256 p1 = 1e18;
        // +0.05% (5e5/1e9) < default 0.1%
        uint256 p2 = (p1 * (BPS_DENOMINATOR + 500_000)) / BPS_DENOMINATOR;

        vm.startPrank(users.operator);
        oracle.updateSharePrice(users.vault, p1);
        skip(1 hours);
        oracle.updateSharePrice(users.vault, p2);
        vm.stopPrank();

        (uint256 latest,) = oracle.getLatestPrice(users.vault);
        assertEq(latest, p2);
    }

    function test_RevertWhen_PerAssetLimitExceeded() external {
        uint32 windowSec = 1 days;
        uint32 maxChangeBps = 100_000; // 0.01%
        vm.prank(users.owner);
        oracle.setAssetConfig(users.vault, windowSec, maxChangeBps);

        uint256 p1 = 1e18;
        uint256 tooHigh = (p1 * (BPS_DENOMINATOR + maxChangeBps + 1)) / BPS_DENOMINATOR;

        vm.startPrank(users.operator);
        oracle.updateSharePrice(users.vault, p1);
        skip(1 hours);

        uint256 diff = tooHigh - p1;
        uint256 expectedDiffBps = (diff * BPS_DENOMINATOR) / p1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IYoOracle.PriceChangeTooBig.selector,
                users.vault,
                tooHigh,
                p1,
                expectedDiffBps,
                uint256(maxChangeBps)
            )
        );
        oracle.updateSharePrice(users.vault, tooHigh);
        vm.stopPrank();
    }

    function test_WhenWindowElapses_AnchorRotates() external {
        uint32 windowSec = 100;
        uint32 maxChangeBps = 1_000_000; // 0.1%
        vm.prank(users.owner);
        oracle.setAssetConfig(users.vault, windowSec, maxChangeBps);

        uint256 p1 = 1e18;
        uint256 p2 = (p1 * (BPS_DENOMINATOR + 500_000)) / BPS_DENOMINATOR;

        vm.startPrank(users.operator);
        oracle.updateSharePrice(users.vault, p1);
        skip(windowSec + 1);
        oracle.updateSharePrice(users.vault, p2);
        vm.stopPrank();

        (uint256 latest,) = oracle.getLatestPrice(users.vault);
        (uint256 anchorPrice,) = oracle.getAnchor(users.vault);
        assertEq(latest, p2);
        assertEq(anchorPrice, p2);
    }

    function test_WhenTwoVaults_TracksIndependently() external {
        vm.startPrank(users.operator);
        oracle.updateSharePrice(users.vault, 1e18);
        oracle.updateSharePrice(users.bob, 2e18);
        vm.stopPrank();

        (uint256 l1,) = oracle.getLatestPrice(users.vault);
        (uint256 l2,) = oracle.getLatestPrice(users.bob);
        assertEq(l1, 1e18);
        assertEq(l2, 2e18);
    }

    function test_GetPricesForUnknownVault_ReturnZero() external view {
        (uint256 latest, uint64 latestTs) = oracle.getLatestPrice(users.eve);
        (uint256 anchorPrice, uint64 anchorTs) = oracle.getAnchor(users.eve);
        assertEq(latest, 0);
        assertEq(latestTs, 0);
        assertEq(anchorPrice, 0);
        assertEq(anchorTs, 0);
    }
}
