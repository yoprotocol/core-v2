// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Offer } from "src/interfaces/IMidnight.sol";
import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";
import { MidnightHashLib } from "src/libraries/MidnightHashLib.sol";

import { Midnight_Integration_Shared } from "../../../MidnightIntegration.t.sol";

contract MakeOrders_Integration_Concrete_Test is Midnight_Integration_Shared {
    function test_RevertWhen_OneOfferInvalid_RatifiesNone() external whenCallerVault whenMarketAllowed {
        Offer memory good = validBuyOffer();
        Offer memory bad = validBuyOffer();
        bad.callback = address(0xCB); // invalid: non-empty callback

        Offer[] memory offers = new Offer[](2);
        offers[0] = good;
        offers[1] = bad;

        vm.expectRevert(IYoMidnightAdapter.CallbackNotEmpty.selector);
        midnightAdapter.makeOrders(offers);

        // The whole batch reverted, so even the first (valid) offer is not ratified.
        assertFalse(setterRatifier.isRootRatified(users.vault, MidnightHashLib.hashOffer(good)), "none ratified");
    }

    function test_WhenAllValid_RatifiesAll() external whenCallerVault whenMarketAllowed {
        Offer memory buy = validBuyOffer();
        Offer memory sell = validSellOffer();

        Offer[] memory offers = new Offer[](2);
        offers[0] = buy;
        offers[1] = sell;

        bytes32 rootBuy = MidnightHashLib.hashOffer(buy);
        bytes32 rootSell = MidnightHashLib.hashOffer(sell);

        vm.expectEmit(true, true, false, true, address(midnightAdapter));
        emit IYoMidnightAdapter.OrderMade(users.vault, marketId(), rootBuy);
        vm.expectEmit(true, true, false, true, address(midnightAdapter));
        emit IYoMidnightAdapter.OrderMade(users.vault, marketId(), rootSell);
        bytes32[] memory roots = midnightAdapter.makeOrders(offers);

        assertEq(roots.length, 2, "roots length");
        assertEq(roots[0], rootBuy, "root0 == hashOffer");
        assertEq(roots[1], rootSell, "root1 == hashOffer");
        assertTrue(setterRatifier.isRootRatified(users.vault, rootBuy), "buy ratified");
        assertTrue(setterRatifier.isRootRatified(users.vault, rootSell), "sell ratified");
    }
}
