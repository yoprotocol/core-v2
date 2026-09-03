// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Errors } from "src/libraries/Errors.sol";

import { ProRata } from "../../../utils/ProRata.sol";
import { YoVaultBase_Test } from "../../concrete/yo-vault/YoVaultBase.t.sol";

contract QueueLifecycleYoVaultIntegrationFuzzTest is YoVaultBase_Test {
    using Math for uint256;

    /// @dev Fulfilling at the request price pays exactly the reserved gross, whatever the oracle
    ///      says at fulfilment, and releases exactly the reserved amount.
    function testFuzz_FulfillAtRequestPrice_PaysReservedGross(uint256 assets, uint256 price) external {
        assets = bound(assets, 1, 500_000e6);
        price = bound(price, 5e5, 2e6);

        (uint256 shares, uint256 reserved) = _queueRedeem(users.alice, 1e6, assets);
        _setOraclePrice(price);
        usdc.mint(address(yoVault), reserved);

        uint256 aliceUsdcBefore = usdc.balanceOf(users.alice);
        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, shares, false);

        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + reserved, "reserved gross paid");
        assertEq(yoVault.balanceOf(address(yoVault)), 0, "escrow burned");
        assertEq(yoVault.totalPendingAssets(), 0, "reserved amount released");
    }

    /// @dev Fulfilling at the current price pays the entry's value at the oracle price in force at
    ///      fulfilment when that price is not above the request price, and refuses otherwise. The
    ///      reserved amount is released exactly either way.
    function testFuzz_FulfillAtCurrentPrice_HaircutOnly(uint256 assets, uint256 price) external {
        assets = bound(assets, 1, 500_000e6);
        price = bound(price, 5e5, 2e6);

        (uint256 shares, uint256 reserved) = _queueRedeem(users.alice, 1e6, assets);
        _setOraclePrice(price);
        uint256 currentValue = shares.mulDiv(price, 10 ** yoVault.decimals(), Math.Rounding.Floor);
        usdc.mint(address(yoVault), reserved);

        uint256 aliceUsdcBefore = usdc.balanceOf(users.alice);
        vm.prank(users.owner);
        if (currentValue > reserved) {
            vm.expectRevert(
                abi.encodeWithSelector(Errors.CurrentPriceAboveRequestPrice.selector, currentValue, reserved)
            );
            yoVault.fulfillRedeem(users.alice, shares, true);
            return;
        }
        if (currentValue == 0) {
            // A haircut to nothing is refused rather than burning shares for zero.
            vm.expectRevert(Errors.InvalidAssetsAmount.selector);
            yoVault.fulfillRedeem(users.alice, shares, true);
            return;
        }
        yoVault.fulfillRedeem(users.alice, shares, true);

        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + currentValue, "current value paid");
        assertEq(yoVault.balanceOf(address(yoVault)), 0, "escrow burned");
        assertEq(yoVault.totalPendingAssets(), 0, "reserved amount released");
    }

    /// @dev Partial fulfilments release the reservation proportionally and the final one takes
    ///      the exact remainder: the payouts sum to the reservation and nothing is left behind.
    function testFuzz_PartialFulfill_ReleasesProportionally(
        uint256 assets,
        uint256 depositPrice,
        uint256 firstShares
    )
        external
    {
        // >= 4 asset wei mint at least 2 shares across the whole price range.
        assets = bound(assets, 4, 500_000e6);
        depositPrice = bound(depositPrice, 5e5, 2e6);

        // A non-parity price so shares and reserved assets differ.
        (uint256 shares, uint256 reserved) = _queueRedeem(users.alice, depositPrice, assets);
        firstShares = bound(firstShares, 1, shares - 1);
        usdc.mint(address(yoVault), reserved);

        uint256 expectedFirst = ProRata.slice(reserved, firstShares, shares);
        // A first slice too small to carry a wei is refused; the whole remainder still settles.
        if (expectedFirst == 0) {
            vm.prank(users.owner);
            vm.expectRevert(Errors.InvalidAssetsAmount.selector);
            yoVault.fulfillRedeem(users.alice, firstShares, false);
            firstShares = 0;
        }

        uint256 aliceUsdcBefore = usdc.balanceOf(users.alice);
        vm.startPrank(users.owner);
        if (firstShares != 0) yoVault.fulfillRedeem(users.alice, firstShares, false);

        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);
        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + expectedFirst, "proportional first payout");
        assertEq(pendingAssets, reserved - expectedFirst, "proportional remainder reserved");
        assertEq(pendingShares, shares - firstShares, "remaining shares pending");
        assertEq(yoVault.totalPendingAssets(), reserved - expectedFirst, "proportional release");

        yoVault.fulfillRedeem(users.alice, shares - firstShares, false);
        vm.stopPrank();

        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + reserved, "payouts sum to the reservation");
        assertEq(yoVault.balanceOf(address(yoVault)), 0, "escrow burned");
        assertEq(yoVault.totalPendingAssets(), 0, "nothing left behind");
    }

    /// @dev Cancel returns every escrowed share and releases the reserved amount exactly.
    function testFuzz_Cancel_ReturnsSharesExactly(uint256 assets) external {
        assets = bound(assets, 1, 500_000e6);

        (uint256 shares,) = _queueRedeem(users.alice, 1e6, assets);

        vm.prank(users.owner);
        yoVault.cancelRedeem(users.alice);

        assertEq(yoVault.balanceOf(users.alice), shares, "all shares returned");
        assertEq(yoVault.balanceOf(address(yoVault)), 0, "escrow cleared");
        assertEq(yoVault.totalPendingAssets(), 0, "reserved amount released");
    }
}
