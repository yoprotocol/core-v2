// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Offer } from "src/interfaces/IMidnight.sol";
import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";
import { MidnightHashLib } from "src/libraries/MidnightHashLib.sol";

import { Midnight_Integration_Shared } from "../../../MidnightIntegration.t.sol";

contract MakeOrder_Integration_Concrete_Test is Midnight_Integration_Shared {
    function test_RevertWhen_MarketNotAllowed() external {
        bytes32 id = marketId();
        Offer memory o = validBuyOffer();

        vm.prank(users.owner);
        midnightRegistry.setAllowed(users.vault, id, false, 0);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.MarketNotAllowed.selector, id));
        midnightAdapter.makeOrder(o);
    }

    function test_RevertWhen_CallerNotMaker() external whenCallerVault whenMarketAllowed {
        Offer memory o = validBuyOffer();
        o.maker = users.eve;
        vm.expectRevert(IYoMidnightAdapter.NotOfferMaker.selector);
        midnightAdapter.makeOrder(o);
    }

    function test_RevertWhen_RatifierInvalid() external whenCallerVault whenMarketAllowed {
        Offer memory o = validBuyOffer();
        o.ratifier = address(0xBAD);
        vm.expectRevert(IYoMidnightAdapter.InvalidRatifier.selector);
        midnightAdapter.makeOrder(o);
    }

    function test_RevertWhen_CallbackNotEmpty() external whenCallerVault whenMarketAllowed {
        Offer memory o = validBuyOffer();
        o.callback = address(0xCB);
        vm.expectRevert(IYoMidnightAdapter.CallbackNotEmpty.selector);
        midnightAdapter.makeOrder(o);
    }

    function test_RevertWhen_InvalidOfferCaps() external whenCallerVault whenMarketAllowed {
        Offer memory o = validBuyOffer();
        // Both caps non-zero violates Midnight's "exactly one" rule.
        o.maxUnits = uint128(TAKE_UNITS);
        vm.expectRevert(IYoMidnightAdapter.InvalidOfferCaps.selector);
        midnightAdapter.makeOrder(o);
    }

    function test_RevertWhen_BuyOfferReceiverNonZero() external whenCallerVault whenMarketAllowed {
        Offer memory o = validBuyOffer();
        o.receiverIfMakerIsSeller = users.vault;
        vm.expectRevert(IYoMidnightAdapter.InvalidReceiver.selector);
        midnightAdapter.makeOrder(o);
    }

    function test_RevertWhen_SellOfferReceiverNotVault() external whenCallerVault whenMarketAllowed {
        Offer memory o = validSellOffer();
        o.receiverIfMakerIsSeller = maker;
        vm.expectRevert(IYoMidnightAdapter.InvalidReceiver.selector);
        midnightAdapter.makeOrder(o);
    }

    function test_RevertWhen_SellOfferNotReduceOnly() external whenCallerVault whenMarketAllowed {
        Offer memory o = validSellOffer();
        o.reduceOnly = false;
        vm.expectRevert(IYoMidnightAdapter.NotReduceOnly.selector);
        midnightAdapter.makeOrder(o);
    }

    function test_RevertWhen_SellCapNotUnits() external whenCallerVault whenMarketAllowed {
        Offer memory o = validSellOffer();
        // Cap by assets instead of units: at a rounding-to-zero price the group's consumed never
        // advances, so the offer would stay refillable. The adapter forbids it for sell offers.
        o.maxUnits = 0;
        o.maxAssets = uint128(MAX_ASSETS);
        vm.expectRevert(IYoMidnightAdapter.SellCapMustBeUnits.selector);
        midnightAdapter.makeOrder(o);
    }

    function test_RevertWhen_SellTickBelowFloor() external whenCallerVault whenMarketAllowed {
        Offer memory o = validSellOffer();
        o.tick = 0; // below the registry MIN_TICK floor
        vm.expectRevert(IYoMidnightAdapter.TickBelowFloor.selector);
        midnightAdapter.makeOrder(o);
    }

    function test_WhenOfferValid_RatifiesAndEmits() external whenCallerVault whenMarketAllowed {
        Offer memory o = validBuyOffer();
        bytes32 expected = MidnightHashLib.hashOffer(o);

        vm.expectEmit(true, true, false, true, address(midnightAdapter));
        emit IYoMidnightAdapter.OrderMade(users.vault, marketId(), expected);
        bytes32 root = midnightAdapter.makeOrder(o);

        assertEq(root, expected, "root == hashOffer");
        assertTrue(setterRatifier.isRootRatified(users.vault, root), "root ratified");
    }

    function test_WhenSellOfferValid_Ratifies() external whenCallerVault whenMarketAllowed {
        Offer memory o = validSellOffer();
        bytes32 root = midnightAdapter.makeOrder(o);
        assertEq(root, MidnightHashLib.hashOffer(o), "root == hashOffer");
        assertTrue(setterRatifier.isRootRatified(users.vault, root), "sell root ratified");
    }
}
