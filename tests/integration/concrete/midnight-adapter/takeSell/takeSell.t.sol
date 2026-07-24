// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";
import { Offer } from "src/interfaces/IMidnight.sol";
import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";

import { Midnight_Integration_Shared } from "../../../MidnightIntegration.t.sol";

contract TakeSell_Integration_Concrete_Test is Midnight_Integration_Shared {
    // priceWad 0.99, fee 0: sellerAssets = floor(units * 0.99).
    uint256 internal constant EXPECTED_SELLER_ASSETS = 9900e6;

    function _seedCreditAndMaker() internal {
        mockMidnight.setCredit(marketId(), users.vault, uint128(TAKE_UNITS));
        _fundMaker(MAX_ASSETS);
    }

    function test_RevertWhen_UnitsZero() external whenCallerVault whenMarketAllowed {
        Offer memory o = makerBuyOffer();
        vm.expectRevert(IYoMidnightAdapter.InvalidAmount.selector);
        midnightAdapter.takeSell(o, "", 0, 0);
    }

    function test_RevertWhen_SellOffer() external whenCallerVault whenMarketAllowed {
        Offer memory o = makerSellOffer(); // buy == false is the wrong side for takeSell
        vm.expectRevert(IYoMidnightAdapter.WrongOfferSide.selector);
        midnightAdapter.takeSell(o, "", TAKE_UNITS, 0);
    }

    function test_RevertWhen_MarketNotAllowed() external {
        bytes32 id = marketId();
        Offer memory o = makerBuyOffer();

        vm.prank(users.owner);
        midnightRegistry.setAllowed(users.vault, id, false, 0);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.MarketNotAllowed.selector, id));
        midnightAdapter.takeSell(o, "", TAKE_UNITS, 0);
    }

    function test_RevertWhen_TickBelowFloor() external whenMarketAllowed {
        // Counterparty buy offer priced below the registry floor: the vault would sell credit too
        // cheaply. The floor check fires before the credit check, so no seeding is needed.
        Offer memory o = makerBuyOffer();
        o.tick = 0;
        vm.prank(users.vault);
        vm.expectRevert(IYoMidnightAdapter.TickBelowFloor.selector);
        midnightAdapter.takeSell(o, "", TAKE_UNITS, 0);
    }

    function test_RevertWhen_InsufficientCredit() external whenMarketAllowed {
        // Vault holds no credit; selling `units` would open a debt position.
        Offer memory o = makerBuyOffer();
        vm.prank(users.vault);
        vm.expectRevert(IYoMidnightAdapter.InsufficientCredit.selector);
        midnightAdapter.takeSell(o, "", TAKE_UNITS, 0);
    }

    function test_RevertWhen_SlippageExceeded() external whenMarketAllowed {
        _seedCreditAndMaker();
        Offer memory o = makerBuyOffer();
        vm.prank(users.vault);
        vm.expectRevert(IYoMidnightAdapter.SlippageExceeded.selector);
        midnightAdapter.takeSell(o, "", TAKE_UNITS, EXPECTED_SELLER_ASSETS + 1);
    }

    function test_WhenSucceeds_SellsCreditToVault() external whenMarketAllowed {
        _seedCreditAndMaker();
        Offer memory o = makerBuyOffer();
        bytes32 id = marketId();
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.expectEmit(true, true, false, true, address(midnightAdapter));
        emit YoMidnightAdapter.MidnightMarketAction(
            users.vault,
            id,
            YoAdapterBase.AdapterDirection.Withdraw,
            TAKE_UNITS,
            EXPECTED_SELLER_ASSETS
        );
        vm.prank(users.vault);
        uint256 sellerAssets = midnightAdapter.takeSell(o, "", TAKE_UNITS, EXPECTED_SELLER_ASSETS);

        assertEq(sellerAssets, EXPECTED_SELLER_ASSETS, "sellerAssets");
        assertEq(usdc.balanceOf(users.vault), vaultBefore + EXPECTED_SELLER_ASSETS, "vault received proceeds");
        assertEq(mockMidnight.credit(id, users.vault), 0, "credit reduced by units");
    }
}
