// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Offer } from "src/interfaces/IMidnight.sol";
import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";
import { MidnightHashLib } from "src/libraries/MidnightHashLib.sol";

import { Midnight_Integration_Shared } from "../../../MidnightIntegration.t.sol";

contract CancelOrder_Integration_Concrete_Test is Midnight_Integration_Shared {
    function test_RevertWhen_CallerNotMaker() external whenCallerVault {
        Offer memory o = validBuyOffer();
        o.maker = users.eve;
        vm.expectRevert(IYoMidnightAdapter.NotOfferMaker.selector);
        midnightAdapter.cancelOrder(o);
    }

    function test_RevertGiven_RootNotRatified() external whenCallerVault whenMarketAllowed {
        // A never-ratified (or field-mutated) offer must not silently emit a cancellation.
        Offer memory o = validBuyOffer();
        vm.expectRevert(IYoMidnightAdapter.RootNotRatified.selector);
        midnightAdapter.cancelOrder(o);
    }

    function test_GivenMarketDelisted_StillUnratifies() external {
        // Ratify while allowlisted, then de-list the market entirely.
        Offer memory o = validBuyOffer();
        bytes32 root = MidnightHashLib.hashOffer(o);

        vm.prank(users.vault);
        midnightAdapter.makeOrder(o);
        assertTrue(setterRatifier.isRootRatified(users.vault, root), "ratified pre-cancel");

        bytes32 id = marketId();
        vm.prank(users.owner);
        midnightRegistry.setAllowed(users.vault, id, false, 0);

        // Cancellation performs no allowlist check, so it still succeeds after de-listing.
        vm.prank(users.vault);
        midnightAdapter.cancelOrder(o);
        assertFalse(setterRatifier.isRootRatified(users.vault, root), "unratified after delist");
    }

    function test_GivenMarketAllowlisted_Unratifies() external whenCallerVault whenMarketAllowed {
        Offer memory o = validBuyOffer();
        bytes32 expected = MidnightHashLib.hashOffer(o);

        midnightAdapter.makeOrder(o);
        assertTrue(setterRatifier.isRootRatified(users.vault, expected), "ratified");

        vm.expectEmit(true, false, false, true, address(midnightAdapter));
        emit IYoMidnightAdapter.OrderCancelled(users.vault, expected);
        bytes32 root = midnightAdapter.cancelOrder(o);

        assertEq(root, expected, "returned root");
        assertFalse(setterRatifier.isRootRatified(users.vault, root), "unratified");
    }
}
