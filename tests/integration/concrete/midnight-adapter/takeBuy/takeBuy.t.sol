// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";
import { Market, Offer } from "src/interfaces/IMidnight.sol";
import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";

import { MockReentrantERC20 } from "../../../../mocks/MockReentrantERC20.sol";
import { Midnight_Integration_Shared } from "../../../MidnightIntegration.t.sol";

contract TakeBuy_Integration_Concrete_Test is Midnight_Integration_Shared {
    // priceWad 0.99, fee 0: buyerAssets = ceil(units * 0.99).
    uint256 internal constant EXPECTED_BUYER_ASSETS = 9900e6;

    function test_RevertWhen_UnitsZero() external whenCallerVault whenMarketAllowed {
        Offer memory o = makerSellOffer();
        vm.expectRevert(IYoMidnightAdapter.InvalidAmount.selector);
        midnightAdapter.takeBuy(o, "", 0, MAX_ASSETS);
    }

    function test_RevertWhen_MaxAssetsZero() external whenCallerVault whenMarketAllowed {
        Offer memory o = makerSellOffer();
        vm.expectRevert(IYoMidnightAdapter.InvalidAmount.selector);
        midnightAdapter.takeBuy(o, "", TAKE_UNITS, 0);
    }

    function test_RevertWhen_BuyOffer() external whenCallerVault whenMarketAllowed {
        Offer memory o = makerBuyOffer(); // buy == true is the wrong side for takeBuy
        vm.expectRevert(IYoMidnightAdapter.WrongOfferSide.selector);
        midnightAdapter.takeBuy(o, "", TAKE_UNITS, MAX_ASSETS);
    }

    function test_RevertWhen_MarketNotAllowed() external {
        bytes32 id = marketId();
        Offer memory o = makerSellOffer();

        vm.prank(users.owner);
        midnightRegistry.setAllowed(users.vault, id, false, 0);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.MarketNotAllowed.selector, id));
        midnightAdapter.takeBuy(o, "", TAKE_UNITS, MAX_ASSETS);
    }

    function test_RevertWhen_Reentered() external {
        // Stand up a reentrant loan token, register it as a Midnight market, allowlist + fund it,
        // then arm the token to re-enter takeBuy during the adapter's `transferFrom` pull.
        MockReentrantERC20 rent = new MockReentrantERC20();
        Market memory m = market();
        m.loanToken = address(rent);
        bytes32 id = mockMidnight.idOf(m);

        vm.prank(users.owner);
        midnightRegistry.setAllowed(users.vault, id, true, MIN_TICK);

        rent.mint(users.vault, MAX_ASSETS * 2);
        vm.prank(users.vault);
        rent.approve(address(midnightAdapter), type(uint256).max);

        Offer memory o = makerSellOffer();
        o.market = m;

        bytes memory payload = abi.encodeCall(IYoMidnightAdapter.takeBuy, (o, "", TAKE_UNITS, MAX_ASSETS));
        rent.arm(address(midnightAdapter), payload);

        vm.prank(users.vault);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        midnightAdapter.takeBuy(o, "", TAKE_UNITS, MAX_ASSETS);
    }

    function test_RevertGiven_NoCreditDelta() external whenCallerVault whenMarketAllowed {
        mockMidnight.setSkipCreditOnTake(true);
        Offer memory o = makerSellOffer();
        vm.expectRevert(IYoMidnightAdapter.NoCreditDelta.selector);
        midnightAdapter.takeBuy(o, "", TAKE_UNITS, MAX_ASSETS);
    }

    function test_WhenSucceeds_BuysCreditAndSweeps() external whenCallerVault whenMarketAllowed {
        Offer memory o = makerSellOffer();
        bytes32 id = marketId();
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.expectEmit(true, true, false, true, address(midnightAdapter));
        emit YoMidnightAdapter.MidnightMarketAction(
            users.vault,
            id,
            YoAdapterBase.AdapterDirection.Deposit,
            TAKE_UNITS,
            EXPECTED_BUYER_ASSETS
        );
        (uint256 buyerAssets, uint256 creditReceived) = midnightAdapter.takeBuy(o, "", TAKE_UNITS, MAX_ASSETS);

        assertEq(buyerAssets, EXPECTED_BUYER_ASSETS, "buyerAssets");
        assertEq(creditReceived, TAKE_UNITS, "creditReceived == units");

        // Vault only spent the buyer assets; the max-assets slack was swept back.
        assertEq(usdc.balanceOf(users.vault), vaultBefore - EXPECTED_BUYER_ASSETS, "vault net spend");
        assertEq(mockMidnight.credit(id, users.vault), TAKE_UNITS, "vault credit");

        // Adapter ends clean.
        assertZeroBalance(address(usdc), address(midnightAdapter));
        assertZeroAllowance(address(usdc), address(midnightAdapter), address(mockMidnight));
    }

    function test_WhenPositionAccruedLoss_CreditDeltaExcludesSlash() external whenCallerVault whenMarketAllowed {
        bytes32 id = marketId();
        // Vault already holds credit that will accrue a loss-factor slash during the buy.
        uint128 existing = 5000e6;
        uint128 slash = 4000e6;
        mockMidnight.setCredit(id, users.vault, existing);
        mockMidnight.setSlash(id, users.vault, slash);

        Offer memory o = makerSellOffer();
        (, uint256 creditReceived) = midnightAdapter.takeBuy(o, "", TAKE_UNITS, MAX_ASSETS);

        // The delta reflects only the units bought — the 4_000e6 slash is not folded in (which would
        // otherwise understate the buy, or underflow-revert when the loss exceeds the purchase).
        assertEq(creditReceived, TAKE_UNITS, "creditReceived excludes accrued loss");
        assertEq(
            mockMidnight.credit(id, users.vault), existing - slash + uint128(TAKE_UNITS), "credit accrued then bought"
        );
    }
}
