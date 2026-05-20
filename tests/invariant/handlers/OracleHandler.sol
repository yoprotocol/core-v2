// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/src/Test.sol";
import { IYoOracle } from "src/interfaces/IYoOracle.sol";
import { YoOracle } from "src/YoOracle.sol";
import { Store } from "./../stores/Store.sol";

/// @notice Drives `updateSharePrice` on the real `YoOracle` and records snapshots so the invariants
///         (`anchor drift`, `latestTs >= anchorTs`, `anchor rotates only after window`) can be
///         enforced from end-of-run state.
contract OracleHandler is Test {
    YoOracle internal oracle;
    address internal vault;
    address internal updater;
    Store internal store;

    uint256 internal lastAnchorPrice;
    uint64 internal lastAnchorTs;
    uint64 internal lastWindowSeconds;
    uint64 internal lastMaxChangeBps;

    constructor(YoOracle _oracle, address _vault, address _updater, Store _store) {
        oracle = _oracle;
        vault = _vault;
        updater = _updater;
        store = _store;
        _snapshot();
    }

    /// @notice Push a new share price within the configured `maxChangeBps` of the current anchor.
    function pushPrice(uint256 priceSeed) external {
        (uint256 anchorPrice,) = oracle.getAnchor(vault);
        if (anchorPrice == 0) return;

        // Generate a price within [anchor * (1 - maxChange), anchor * (1 + maxChange)]; the
        // contract floor-rounds so staying strictly inside the band is safest.
        uint64 maxBps = lastMaxChangeBps == 0 ? oracle.DEFAULT_MAX_CHANGE_BPS() : lastMaxChangeBps;
        uint64 bpsDenom = oracle.BPS_DENOMINATOR();

        uint256 maxDelta = (anchorPrice * uint256(maxBps)) / uint256(bpsDenom);
        // Keep one wei of room below the boundary so floor-rounding can't trip the strict-> check.
        if (maxDelta > 0) maxDelta -= 1;
        uint256 newPrice = bound(priceSeed, anchorPrice - maxDelta, anchorPrice + maxDelta);
        if (newPrice == 0) newPrice = 1;

        vm.prank(updater);
        try oracle.updateSharePrice(vault, newPrice) {
            _checkInvariants();
            _snapshot();
        } catch { }
    }

    /// @notice Advance time so the anchor window can rotate; tests both "within window" and
    ///         "after window" branches.
    function warp(uint256 secondsSeed) external {
        // 0 → 2× the configured window. Bias toward "just-rotated" cases.
        uint64 window = lastWindowSeconds == 0 ? oracle.DEFAULT_WINDOW_SECONDS() : lastWindowSeconds;
        uint256 delta = bound(secondsSeed, 0, uint256(window) * 2);
        vm.warp(block.timestamp + delta);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   INVARIANTS
    //////////////////////////////////////////////////////////////////////////*/

    function _snapshot() internal {
        IYoOracle.AssetOracleData memory d = _read();
        lastAnchorPrice = d.anchorPrice;
        lastAnchorTs = d.anchorTimestamp;
        lastWindowSeconds = d.windowSeconds == 0 ? oracle.DEFAULT_WINDOW_SECONDS() : d.windowSeconds;
        lastMaxChangeBps = d.maxChangeBps == 0 ? oracle.DEFAULT_MAX_CHANGE_BPS() : d.maxChangeBps;
    }

    function _checkInvariants() internal {
        IYoOracle.AssetOracleData memory d = _read();

        // latestTs >= anchorTs and latestTs <= now.
        if (d.latestTimestamp < d.anchorTimestamp || d.latestTimestamp > block.timestamp) {
            store.flagOracleViolation();
        }

        // |latest - anchor| / anchor <= maxChangeBps.
        if (d.anchorPrice > 0) {
            uint256 diff = d.latestPrice > d.anchorPrice ? d.latestPrice - d.anchorPrice : d.anchorPrice - d.latestPrice;
            uint256 diffBps = (diff * uint256(oracle.BPS_DENOMINATOR())) / d.anchorPrice;
            uint64 maxBps = d.maxChangeBps == 0 ? oracle.DEFAULT_MAX_CHANGE_BPS() : d.maxChangeBps;
            if (diffBps > uint256(maxBps)) {
                store.flagOracleViolation();
            }
        }

        // anchor rotates ⇒ at least `windowSeconds` elapsed since last anchorTs snapshot.
        if (d.anchorTimestamp != lastAnchorTs) {
            if (d.anchorTimestamp - lastAnchorTs < lastWindowSeconds) {
                store.flagOracleViolation();
            }
        }
    }

    function _read() internal view returns (IYoOracle.AssetOracleData memory d) {
        (d.latestPrice, d.anchorPrice, d.anchorTimestamp, d.latestTimestamp, d.windowSeconds, d.maxChangeBps) =
            oracle.oracleData(vault);
    }
}
