// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Errors } from "src/libraries/Errors.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

/// @dev Hand-computed rounding shapes for partial fulfilment. Amounts are in asset wei so the
///      arithmetic is visible: shares = floor(deposit * 1e6 / price), reserved = floor(shares *
///      price / 1e6), and each partial releases floor(reserved * slice / shares) until the last
///      slice takes the remainder.
contract FulfillRedeemRoundingIntegrationConcreteTest is YoVaultBase_Test {
    function _queueAt(uint256 price, uint256 assets) internal returns (uint256 shares, uint256 reserved) {
        return _queueRedeem(users.alice, price, assets);
    }

    /// @dev Fulfil `shares` at the request price and return what alice was paid.
    function _fulfil(uint256 shares) internal returns (uint256 paid) {
        uint256 before = usdc.balanceOf(users.alice);
        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, shares, false);
        paid = usdc.balanceOf(users.alice) - before;
    }

    function _pending() internal view returns (uint256 assets, uint256 shares) {
        return yoVault.pendingRedeemRequest(users.alice);
    }

    function test_WhenTheReservationDoesNotDivideEvenlyAcrossTwoPartials() external {
        // price 1.5: 3 wei deposit -> 2 shares -> reserved floor(3.0) = 3.
        (uint256 shares, uint256 reserved) = _queueAt(1_500_000, 3);
        assertEq(shares, 2);
        assertEq(reserved, 3);
        usdc.mint(address(yoVault), reserved);

        // it should floor the first slice: floor(3 * 1 / 2) = 1
        assertEq(_fulfil(1), 1, "first slice floored");
        (uint256 assets, uint256 left) = _pending();
        assertEq(assets, 2, "remainder keeps the rounding wei");
        assertEq(left, 1);
        assertEq(yoVault.totalPendingAssets(), 2);

        // it should pay the exact remainder on the last slice
        assertEq(_fulfil(1), 2, "last slice takes the remainder");
        (assets, left) = _pending();
        assertEq(assets, 0);
        assertEq(left, 0);
        assertEq(yoVault.totalPendingAssets(), 0);
    }

    function test_WhenTheEntryIsDrainedOneShareAtATime() external {
        // price 1.4: 7 wei deposit -> 5 shares -> reserved floor(7.0) = 7.
        (uint256 shares, uint256 reserved) = _queueAt(1_400_000, 7);
        assertEq(shares, 5);
        assertEq(reserved, 7);
        usdc.mint(address(yoVault), reserved);

        // Slices: floor(7/5)=1, floor(6/4)=1, floor(5/3)=1, floor(4/2)=2, remainder 2.
        uint256[5] memory expected = [uint256(1), 1, 1, 2, 2];
        uint256 total;
        for (uint256 i; i < 5; ++i) {
            uint256 paid = _fulfil(1);
            assertEq(paid, expected[i], "slice payout");
            total += paid;
        }
        assertEq(total, reserved, "payouts sum to the reservation");
        assertEq(yoVault.totalPendingAssets(), 0);
    }

    function test_WhenTheReservationIsBelowTheShareCount() external {
        // price 0.6: 3 wei deposit -> 5 shares -> reserved floor(3.0) = 3.
        (uint256 shares, uint256 reserved) = _queueAt(600_000, 3);
        assertEq(shares, 5);
        assertEq(reserved, 3);
        usdc.mint(address(yoVault), reserved);

        assertEq(_fulfil(2), 1, "floor(3 * 2 / 5)");
        (uint256 assets, uint256 left) = _pending();
        assertEq(assets, 2);
        assertEq(left, 3);
        assertEq(_fulfil(3), 2, "remainder");
        assertEq(yoVault.totalPendingAssets(), 0);
    }

    function test_WhenTheEntryAccumulatedRequestsAtTwoPrices() external {
        // price 1.0: 3 wei -> 3 shares, reserved 3. price 2.0: 3 wei -> 1 share, reserved 2.
        _queueAt(1_000_000, 3);
        _queueAt(2_000_000, 3);
        (uint256 assets, uint256 shares) = _pending();
        assertEq(assets, 5);
        assertEq(shares, 4);
        usdc.mint(address(yoVault), assets);

        assertEq(_fulfil(2), 2, "floor(5 * 2 / 4)");
        assertEq(_fulfil(1), 1, "floor(3 * 1 / 2)");
        assertEq(_fulfil(1), 2, "remainder");
        (assets, shares) = _pending();
        assertEq(assets, 0);
        assertEq(shares, 0);
        assertEq(yoVault.totalPendingAssets(), 0);
    }

    function test_WhenASlicesProportionalReservationFloorsToZero() external {
        // price 0.6: 3 wei -> 5 shares, reserved 3. One share is worth floor(3/5) = 0.
        (, uint256 reserved) = _queueAt(600_000, 3);
        usdc.mint(address(yoVault), reserved);

        // it should refuse the slice
        vm.prank(users.owner);
        vm.expectRevert(Errors.InvalidAssetsAmount.selector);
        yoVault.fulfillRedeem(users.alice, 1, false);
        (uint256 assets, uint256 left) = _pending();
        assertEq(assets, 3, "reservation intact");
        assertEq(left, 5, "no share burned");

        // it should settle a slice that carries a wei: floor(3 * 2 / 5) = 1
        assertEq(_fulfil(2), 1, "two shares carry a wei");
        assertEq(_fulfil(3), 2, "remainder pays the rest");
        assertEq(yoVault.totalPendingAssets(), 0);
    }

    function test_WhenFulfilledAtTheUnchangedCurrentPriceAfterAPartial() external {
        // price 1.5: 3 wei -> 2 shares, reserved 3. Partial 1 at request price -> entry (2, 1).
        (, uint256 reserved) = _queueAt(1_500_000, 3);
        usdc.mint(address(yoVault), reserved);
        _fulfil(1);

        // Current value of the remaining share is floor(1.5) = 1 <= 2: the guard passes.
        uint256 before = usdc.balanceOf(users.alice);
        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, 1, true);

        assertEq(usdc.balanceOf(users.alice) - before, 1, "paid the current value");
        assertEq(yoVault.totalPendingAssets(), 0, "full reservation released");
        assertEq(usdc.balanceOf(address(yoVault)), 1, "rounding wei stays in the vault");
    }

    function test_WhenFulfilledPartiallyAtADroppedCurrentPrice() external {
        // parity: 100e6 wei -> 100e6 shares, reserved 100e6. Then a 10% drop.
        (, uint256 reserved) = _queueAt(1_000_000, 100e6);
        usdc.mint(address(yoVault), reserved);
        _setOraclePrice(900_000);

        uint256 before = usdc.balanceOf(users.alice);
        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, 40e6, true);

        // it should pay the floored pro-rata current value: floor(90e6 * 40e6 / 100e6) = 36e6
        assertEq(usdc.balanceOf(users.alice) - before, 36e6, "pro-rata of the current value");
        // it should release the floored pro-rata reservation: floor(100e6 * 40e6 / 100e6) = 40e6
        assertEq(yoVault.totalPendingAssets(), 60e6, "pro-rata of the reservation");

        before = usdc.balanceOf(users.alice);
        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, 60e6, true);
        assertEq(usdc.balanceOf(users.alice) - before, 54e6, "final slice: floor(60e6 * 0.9)");
        assertEq(yoVault.totalPendingAssets(), 0);
    }

    function test_WhenAnAccumulatedEntryIsSettledAtTheUnchangedCurrentPrice() external {
        // price 1.5: 5 wei -> 3 shares reserving floor(4.5) = 4; 2 wei -> 1 share reserving
        // floor(1.5) = 1. Entry {5, 4}, but the whole entry is worth floor(4 * 1.5) = 6 today.
        _queueAt(1_500_000, 5);
        _queueAt(1_500_000, 2);
        (uint256 assets, uint256 shares) = _pending();
        assertEq(assets, 5);
        assertEq(shares, 4);
        usdc.mint(address(yoVault), assets);

        // it should refuse by the per-request rounding slack
        vm.prank(users.owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.CurrentPriceAboveRequestPrice.selector, 6, 5));
        yoVault.fulfillRedeem(users.alice, 4, true);

        // it should settle at the request price instead
        assertEq(_fulfil(4), 5, "request price pays the reservation");
        assertEq(yoVault.totalPendingAssets(), 0);
    }

    function test_WhenTheLastSliceIsOneShare() external {
        // price 1.4: 7 wei -> 5 shares, reserved 7.
        (, uint256 reserved) = _queueAt(1_400_000, 7);
        usdc.mint(address(yoVault), reserved);

        assertEq(_fulfil(4), 5, "floor(7 * 4 / 5)");
        (uint256 assets, uint256 left) = _pending();
        assertEq(assets, 2);
        assertEq(left, 1);
        assertEq(_fulfil(1), 2, "final share takes the remainder");
        assertEq(yoVault.totalPendingAssets(), 0);
    }
}
