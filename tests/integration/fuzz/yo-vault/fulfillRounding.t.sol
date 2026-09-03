// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Errors } from "src/libraries/Errors.sol";

import { ProRata } from "../../../utils/ProRata.sol";
import { YoVaultBase_Test } from "../../concrete/yo-vault/YoVaultBase.t.sol";

/// @dev Rounding properties of partial fulfilment under arbitrary split sequences, entries
///      accumulated at two prices, and both price modes. Deposits start at 2 wei so the wei-scale
///      region — where flooring and the zero-gross refusal are visible — is inside the search space.
contract FulfillRoundingYoVaultIntegrationFuzzTest is YoVaultBase_Test {
    using Math for uint256;

    uint256 internal constant MAX_STEPS = 8;
    uint256 internal constant MIN_PRICE = 5e5;
    uint256 internal constant MAX_PRICE = 2e6;
    /// @dev Two wei mint at least one share and reserve at least one wei across the price band.
    uint256 internal constant MIN_DEPOSIT = 2;
    uint256 internal constant MAX_DEPOSIT = 500_000e6;

    /// @dev Build alice's entry from two requests at two prices and fund it. Returns the entry and
    ///      the lower of the two request prices.
    function _buildEntry(
        uint256 d1,
        uint256 p1,
        uint256 d2,
        uint256 p2
    )
        internal
        returns (uint256 assets, uint256 shares, uint256 lowerPrice)
    {
        d1 = bound(d1, MIN_DEPOSIT, MAX_DEPOSIT);
        d2 = bound(d2, MIN_DEPOSIT, MAX_DEPOSIT);
        p1 = bound(p1, MIN_PRICE, MAX_PRICE);
        p2 = bound(p2, MIN_PRICE, MAX_PRICE);
        _queueRedeem(users.alice, p1, d1);
        _queueRedeem(users.alice, p2, d2);
        (assets, shares) = yoVault.pendingRedeemRequest(users.alice);
        lowerPrice = Math.min(p1, p2);
        usdc.mint(address(yoVault), assets);
    }

    /// @dev Slice for `step`: fuzz-chosen, or the whole remainder on the last step.
    function _slice(uint256[MAX_STEPS] calldata seeds, uint256 step, uint256 remaining)
        internal
        pure
        returns (uint256)
    {
        return step == MAX_STEPS - 1 ? remaining : bound(seeds[step], 1, remaining);
    }

    function _fulfil(uint256 shares, bool atCurrentPrice) internal returns (uint256 paid) {
        uint256 before = usdc.balanceOf(users.alice);
        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, shares, atCurrentPrice);
        paid = usdc.balanceOf(users.alice) - before;
    }

    function _expectRefused(uint256 shares, bool atCurrentPrice, bytes memory err) internal {
        vm.prank(users.owner);
        vm.expectRevert(err);
        yoVault.fulfillRedeem(users.alice, shares, atCurrentPrice);
    }

    /// @dev Any sequence of partials at the request price pays, per slice, exactly the floored
    ///      pro-rata reservation, and in total exactly the reservation — nothing lost, nothing extra.
    ///      A slice whose gross rounds to zero is refused and changes nothing; the final step settles
    ///      the whole remainder, which always carries at least one wei.
    function testFuzz_PartialSequence_RequestPrice_ConservesReservation(
        uint256 d1,
        uint256 p1,
        uint256 d2,
        uint256 p2,
        uint256[MAX_STEPS] calldata sliceSeeds
    )
        external
    {
        (uint256 reserved, uint256 shares,) = _buildEntry(d1, p1, d2, p2);
        uint256 totalPaid;
        uint256 remainingAssets = reserved;
        uint256 remainingShares = shares;

        for (uint256 step; step < MAX_STEPS && remainingShares > 0; ++step) {
            uint256 slice = _slice(sliceSeeds, step, remainingShares);
            uint256 expected = ProRata.slice(remainingAssets, slice, remainingShares);
            if (expected == 0) {
                _expectRefused(slice, false, abi.encodeWithSelector(Errors.InvalidAssetsAmount.selector));
                continue;
            }

            uint256 paid = _fulfil(slice, false);
            assertEq(paid, expected, "slice pays the floored pro-rata reservation");
            remainingAssets -= paid;
            remainingShares -= slice;
            totalPaid += paid;

            (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);
            assertEq(pendingAssets, remainingAssets, "entry assets track the release");
            assertEq(pendingShares, remainingShares, "entry shares track the burn");
            assertEq(yoVault.totalPendingAssets(), remainingAssets, "ledger tracks the release");
            assertEq(yoVault.balanceOf(address(yoVault)), remainingShares, "escrow tracks the burn");
        }

        assertEq(remainingShares, 0, "the whole remainder always settles");
        assertEq(totalPaid, reserved, "payouts sum to the reservation exactly");
    }

    /// @dev Under a haircut, any sequence of partials at the current price pays, per slice, the
    ///      floored pro-rata share of the entry's current value and never more than the reservation
    ///      released for it. Whatever the loop leaves — a refused zero-gross slice, or a guard trip
    ///      from wei-scale rounding — the request price settles, so the sequence always terminates
    ///      with the entry drained and the total never above the reservation.
    function testFuzz_PartialSequence_CurrentPrice_NeverExceedsRelease(
        uint256 d1,
        uint256 p1,
        uint256 d2,
        uint256 p2,
        uint256 haircutBps,
        uint256[MAX_STEPS] calldata sliceSeeds
    )
        external
    {
        (uint256 reserved, uint256 shares, uint256 lowerPrice) = _buildEntry(d1, p1, d2, p2);
        haircutBps = bound(haircutBps, 5000, 9900);
        _setOraclePrice((lowerPrice * haircutBps) / 10_000);

        uint256 totalPaid;
        uint256 remainingAssets = reserved;
        uint256 remainingShares = shares;

        for (uint256 step; step < MAX_STEPS && remainingShares > 0; ++step) {
            uint256 slice = _slice(sliceSeeds, step, remainingShares);
            uint256 released = ProRata.slice(remainingAssets, slice, remainingShares);
            uint256 currentValue = yoVault.convertToAssets(remainingShares);
            if (currentValue > remainingAssets) {
                // Wei-scale slack of the per-request floors: the guard refuses; nothing changes.
                _expectRefused(
                    slice,
                    true,
                    abi.encodeWithSelector(Errors.CurrentPriceAboveRequestPrice.selector, currentValue, remainingAssets)
                );
                break;
            }
            uint256 expected = ProRata.slice(currentValue, slice, remainingShares);
            if (expected == 0) {
                _expectRefused(slice, true, abi.encodeWithSelector(Errors.InvalidAssetsAmount.selector));
                continue;
            }

            uint256 paid = _fulfil(slice, true);
            assertEq(paid, expected, "slice pays the floored pro-rata current value");
            assertLe(paid, released, "never more than the reservation released");
            remainingAssets -= released;
            remainingShares -= slice;
            totalPaid += paid;
            assertEq(yoVault.totalPendingAssets(), remainingAssets, "reservation released exactly");
        }

        if (remainingShares > 0) {
            uint256 paid = _fulfil(remainingShares, false);
            assertEq(paid, remainingAssets, "the request price settles the remainder exactly");
            totalPaid += paid;
        }

        assertLe(totalPaid, reserved, "total never exceeds the reservation");
        assertEq(yoVault.totalPendingAssets(), 0, "nothing left reserved");
        assertEq(yoVault.balanceOf(address(yoVault)), 0, "escrow drained");
    }

    /// @dev For a single-request entry, the guard never trips at the unchanged price after any
    ///      partial prefix, and it trips exactly when the entry's current value exceeds its
    ///      reservation.
    function testFuzz_Guard_TripsIffCurrentValueExceedsReservation(
        uint256 deposit,
        uint256 requestPrice,
        uint256 prefixShares,
        uint256 currentPrice,
        uint256 slice
    )
        external
    {
        deposit = bound(deposit, MIN_DEPOSIT, MAX_DEPOSIT);
        requestPrice = bound(requestPrice, MIN_PRICE, MAX_PRICE);
        (uint256 shares, uint256 reserved) = _queueRedeem(users.alice, requestPrice, deposit);
        usdc.mint(address(yoVault), reserved);

        // A partial prefix at the request price, skipped when it would carry no wei.
        prefixShares = bound(prefixShares, 0, shares - 1);
        if (prefixShares > 0 && ProRata.slice(reserved, prefixShares, shares) != 0) {
            _fulfil(prefixShares, false);
        }
        (uint256 remainingAssets, uint256 remainingShares) = yoVault.pendingRedeemRequest(users.alice);

        // At the unchanged price the guard must pass: floor(S' * p) <= A' holds for a single request.
        assertLe(yoVault.convertToAssets(remainingShares), remainingAssets, "unchanged price never trips");

        currentPrice = bound(currentPrice, MIN_PRICE, MAX_PRICE);
        _setOraclePrice(currentPrice);
        uint256 currentValue = yoVault.convertToAssets(remainingShares);
        slice = bound(slice, 1, remainingShares);

        if (currentValue > remainingAssets) {
            _expectRefused(
                slice,
                true,
                abi.encodeWithSelector(Errors.CurrentPriceAboveRequestPrice.selector, currentValue, remainingAssets)
            );
            return;
        }
        uint256 expected = ProRata.slice(currentValue, slice, remainingShares);
        if (expected == 0) {
            _expectRefused(slice, true, abi.encodeWithSelector(Errors.InvalidAssetsAmount.selector));
            return;
        }
        assertEq(_fulfil(slice, true), expected, "pro-rata current value paid");
    }

    /// @dev Accumulated entries floor each request's reservation separately, so at an unchanged
    ///      price the entry's current value can exceed the reservation by at most one wei per
    ///      request — the guard may refuse by that margin, and never by more.
    function testFuzz_Guard_AccumulatedEntry_UnchangedPriceSlackIsBoundedByRequestCount(
        uint256 d1,
        uint256 d2,
        uint256 price
    )
        external
    {
        d1 = bound(d1, MIN_DEPOSIT, MAX_DEPOSIT);
        d2 = bound(d2, MIN_DEPOSIT, MAX_DEPOSIT);
        price = bound(price, MIN_PRICE, MAX_PRICE);
        _queueRedeem(users.alice, price, d1);
        _queueRedeem(users.alice, price, d2);
        (uint256 reserved, uint256 shares) = yoVault.pendingRedeemRequest(users.alice);

        assertLe(yoVault.convertToAssets(shares), reserved + 1, "slack bounded by (requests - 1) wei");
    }
}
