// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";
import { Id, MarketParams } from "src/interfaces/IMorpho.sol";
import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";
import { Offer } from "src/vendor/morpho-midnight/interfaces/IMidnight.sol";
import { HashLib } from "src/vendor/morpho-midnight/ratifiers/libraries/HashLib.sol";

import { MidnightAdapter_Integration_Concrete_Test } from "../MidnightAdapter.t.sol";

contract Ratify_Integration_Concrete_Test is MidnightAdapter_Integration_Concrete_Test {
    function _expectRatifyRevert(Offer memory offer, bytes memory reason) internal {
        vm.prank(users.vault);
        vm.expectRevert(reason);
        midnightAdapter.ratify(_offers(offer, 1));
    }

    function test_WhenOffersEmpty() external whenCallerVault {
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.LeafCountNotPowerOfTwo.selector, 0));
        midnightAdapter.ratify(new Offer[](0));
    }

    function test_WhenOfferCountNotPowerOfTwo() external {
        Offer[] memory offers = _offers(_offer(), 3);
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.LeafCountNotPowerOfTwo.selector, 3));
        midnightAdapter.ratify(offers);
    }

    function test_WhenMakerNotVault() external {
        Offer memory offer = _offer();
        offer.maker = users.eve;
        _expectRatifyRevert(offer, abi.encodeWithSelector(IYoMidnightAdapter.InvalidMaker.selector, 0));
    }

    function test_WhenOfferIsSell() external {
        Offer memory offer = _offer();
        offer.buy = false;
        _expectRatifyRevert(offer, abi.encodeWithSelector(IYoMidnightAdapter.NotBuyOffer.selector, 0));
    }

    function test_WhenRatifierNotSetterRatifier() external {
        Offer memory offer = _offer();
        offer.ratifier = makeAddr("OtherRatifier");
        _expectRatifyRevert(offer, abi.encodeWithSelector(IYoMidnightAdapter.InvalidRatifier.selector, 0));
    }

    function test_WhenTemplateNotAllowlisted() external {
        Offer memory offer = _offer();
        offer.market.collateralParams[0].oracle = makeAddr("AttackerOracle");
        Id template = midnightAdapter.templateId(offer.market);
        _expectRatifyRevert(offer, abi.encodeWithSelector(IYoMidnightAdapter.TemplateNotAllowed.selector, 0, template));
    }

    function test_WhenMaturityPassed() external {
        Offer memory offer = _offer();
        offer.market.maturity = block.timestamp;
        offer.expiry = block.timestamp;
        _expectRatifyRevert(offer, abi.encodeWithSelector(IYoMidnightAdapter.MaturityOutOfRange.selector, 0));
    }

    function test_WhenMaturityBeyondMaxTimeToMaturity() external {
        Offer memory offer = _offer();
        offer.market.maturity = block.timestamp + MAX_TIME_TO_MATURITY + 1;
        offer.expiry = offer.market.maturity;
        _expectRatifyRevert(offer, abi.encodeWithSelector(IYoMidnightAdapter.MaturityOutOfRange.selector, 0));
    }

    function test_WhenExpiryAfterMaturity() external {
        Offer memory offer = _offer();
        offer.expiry = offer.market.maturity + 1;
        _expectRatifyRevert(offer, abi.encodeWithSelector(IYoMidnightAdapter.ExpiryAfterMaturity.selector, 0));
    }

    function test_WhenContinuousFeeCapAboveMax() external {
        Offer memory offer = _offer();
        offer.continuousFeeCap = MAX_CONTINUOUS_FEE_CAP + 1;
        _expectRatifyRevert(offer, abi.encodeWithSelector(IYoMidnightAdapter.ContinuousFeeCapTooHigh.selector, 0));
    }

    function test_WhenCallbackNotCreatedByFactory() external {
        Offer memory offer = _offer();
        offer.callback = makeAddr("FakeCallback");
        _expectRatifyRevert(
            offer, abi.encodeWithSelector(IYoMidnightAdapter.OfferCallbackNotAllowed.selector, 0, offer.callback)
        );
    }

    function test_WhenCallbackNotOwnedByVault() external {
        Offer memory offer = _offer();
        offer.callback = eveCallback;
        _expectRatifyRevert(
            offer, abi.encodeWithSelector(IYoMidnightAdapter.OfferCallbackNotAllowed.selector, 0, eveCallback)
        );
    }

    function test_WhenFundingMarketNotAllowlisted() external {
        MarketParams memory p = fundingParams;
        p.collateralToken = makeAddr("OtherCollateral");
        Offer memory offer = _offer();
        offer.callbackData = abi.encode(p);
        Id blueId = Id.wrap(keccak256(abi.encode(p)));
        _expectRatifyRevert(
            offer, abi.encodeWithSelector(IYoMidnightAdapter.FundingMarketNotAllowed.selector, 0, blueId)
        );
    }

    function test_WhenFundingLoanTokenDiffersFromMarketLoanToken() external {
        MarketParams memory p = fundingParams;
        p.loanToken = address(usdt);
        _allowMarket(users.vault, Id.wrap(keccak256(abi.encode(p))));
        Offer memory offer = _offer();
        offer.callbackData = abi.encode(p);
        _expectRatifyRevert(offer, abi.encodeWithSelector(IYoMidnightAdapter.LoanTokenMismatch.selector, 0));
    }

    function test_WhenOnlyALaterLeafIsInvalid() external {
        Offer[] memory offers = _offers(_offer(), 4);
        offers[3].maker = users.eve;
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.InvalidMaker.selector, 3));
        midnightAdapter.ratify(offers);
    }

    function test_GivenAdapterNotAuthorizedOnMidnight() external {
        vm.prank(users.vault);
        mockMidnight.setIsAuthorized(address(midnightAdapter), false, users.vault);

        Offer[] memory offers = _offers(_offer(), 1);
        vm.prank(users.vault);
        vm.expectRevert(bytes("unauthorized"));
        midnightAdapter.ratify(offers);
    }

    function test_WhenOfferMaturityDiffersFromAllowlistedTemplateMaturity() external {
        Offer memory offer = _offer();
        offer.market.maturity = block.timestamp + 45 days;
        offer.expiry = offer.market.maturity;

        vm.prank(users.vault);
        bytes32 root = midnightAdapter.ratify(_offers(offer, 1));

        assertTrue(mockRatifier.isRootRatified(users.vault, root), "ratified");
    }

    function test_WhenMaturityEqualsMaxTimeToMaturityAndExpiryEqualsMaturity() external {
        Offer memory offer = _offer();
        offer.market.maturity = block.timestamp + MAX_TIME_TO_MATURITY;
        offer.expiry = offer.market.maturity;

        vm.prank(users.vault);
        bytes32 root = midnightAdapter.ratify(_offers(offer, 1));

        assertTrue(mockRatifier.isRootRatified(users.vault, root), "ratified");
    }

    function test_WhenOfferMaturityEqualsAllowlistedTemplateMaturity() external {
        Offer[] memory offers = _offers(_offer(), 2);
        offers[1].tick = 6004;
        bytes32 expectedRoot = keccak256(abi.encode(HashLib.hashOffer(offers[0]), HashLib.hashOffer(offers[1])));

        vm.expectEmit(address(midnightAdapter));
        emit YoMidnightAdapter.MidnightRootSet(users.vault, expectedRoot, true, 2);

        vm.prank(users.vault);
        bytes32 root = midnightAdapter.ratify(offers);

        assertEq(root, expectedRoot, "root");
        assertTrue(mockRatifier.isRootRatified(users.vault, root), "ratified");
    }
}
