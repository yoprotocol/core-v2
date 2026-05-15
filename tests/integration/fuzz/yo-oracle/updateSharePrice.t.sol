// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoOracle } from "src/interfaces/IYoOracle.sol";

import { YoOracleBase_Test } from "../../concrete/yo-oracle/YoOracleBase.t.sol";

contract UpdateSharePrice_YoOracle_Integration_Fuzz_Test is YoOracleBase_Test {
    /// @dev Any first price > 0 initializes latest == anchor == price.
    function testFuzz_FirstUpdate_SetsBothFields(uint256 price) external {
        price = bound(price, 1, 1e30);

        vm.prank(users.operator);
        oracle.updateSharePrice(users.vault, price);

        (uint256 latest,) = oracle.getLatestPrice(users.vault);
        (uint256 anchor,) = oracle.getAnchor(users.vault);
        assertEq(latest, price);
        assertEq(anchor, price);
    }

    /// @dev For any price within the configured max-change limit, the second update succeeds.
    ///      For any price *outside* the limit, it reverts with PriceChangeTooBig.
    function testFuzz_SecondUpdate_RespectsLimit(uint256 p1, uint256 p2) external {
        // Stay in a band where (p1 * BPS_DENOMINATOR) does not overflow uint256.
        p1 = bound(p1, 1e9, 1e30);
        p2 = bound(p2, 1, 1e30);

        vm.startPrank(users.operator);
        oracle.updateSharePrice(users.vault, p1);
        skip(1);

        uint256 diff = p2 > p1 ? p2 - p1 : p1 - p2;
        uint256 diffBps = (diff * BPS_DENOMINATOR) / p1;
        bool shouldRevert = diffBps > DEFAULT_MAX_CHANGE_BPS;

        if (shouldRevert) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IYoOracle.PriceChangeTooBig.selector, users.vault, p2, p1, diffBps, uint256(DEFAULT_MAX_CHANGE_BPS)
                )
            );
            oracle.updateSharePrice(users.vault, p2);
        } else {
            oracle.updateSharePrice(users.vault, p2);
            (uint256 latest,) = oracle.getLatestPrice(users.vault);
            assertEq(latest, p2);
        }
        vm.stopPrank();
    }

    /// @dev Anchor rotates to the new price after exactly `windowSec` seconds.
    function testFuzz_AnchorRotation(uint32 windowSec) external {
        windowSec = uint32(bound(uint256(windowSec), 1, 365 days));
        // Use the per-asset config path (default would clamp differently); keep a wide max-change
        // so the limit doesn't reject our test prices.
        vm.prank(users.owner);
        oracle.setAssetConfig(users.vault, windowSec, 50_000_000); // 5%

        uint256 p1 = 1e18;
        uint256 p2 = (p1 * (BPS_DENOMINATOR + 1_000_000)) / BPS_DENOMINATOR; // +0.1%

        vm.startPrank(users.operator);
        oracle.updateSharePrice(users.vault, p1);
        skip(uint256(windowSec) + 1);
        oracle.updateSharePrice(users.vault, p2);
        vm.stopPrank();

        (uint256 anchor,) = oracle.getAnchor(users.vault);
        assertEq(anchor, p2, "anchor rotated");
    }
}
