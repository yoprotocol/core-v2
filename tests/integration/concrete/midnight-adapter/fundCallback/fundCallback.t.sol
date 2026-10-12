// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";
import { Id, MarketParams } from "src/interfaces/IMorpho.sol";
import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";

import { MidnightAdapter_Integration_Concrete_Test } from "../MidnightAdapter.t.sol";

contract FundCallback_Integration_Concrete_Test is MidnightAdapter_Integration_Concrete_Test {
    function test_WhenAssetsZero() external whenCallerVault {
        vm.expectRevert(IYoMidnightAdapter.InvalidAmount.selector);
        midnightAdapter.fundCallback(callback, fundingId, 0);
    }

    function test_WhenFundingMarketNotAllowlistedForVault() external whenCallerVault {
        Id m = defaults.MARKET_B();
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.MarketNotAllowed.selector, m));
        midnightAdapter.fundCallback(callback, m, FUND_AMOUNT);
    }

    function test_WhenCallbackNotCreatedByFactory() external whenCallerVault {
        address fake = makeAddr("FakeCallback");
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.InvalidCallback.selector, fake));
        midnightAdapter.fundCallback(fake, fundingId, FUND_AMOUNT);
    }

    function test_WhenCallbackOwnedByAnotherVault() external whenCallerVault {
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.InvalidCallback.selector, eveCallback));
        midnightAdapter.fundCallback(eveCallback, fundingId, FUND_AMOUNT);
    }

    function test_GivenCallbackHasNotAuthorizedAdapterOnMorpho() external {
        address unauthorized = mockCallbackFactory.createBlueBuyCallback(users.vault);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.CallbackNotAuthorized.selector, unauthorized));
        midnightAdapter.fundCallback(unauthorized, fundingId, FUND_AMOUNT);
    }

    function test_GivenIdToMarketParamsReturnsZeroLoanToken() external {
        Id m = Id.wrap(keccak256("UNKNOWN_MARKET"));
        _allowMarket(users.vault, m);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.UnknownMarket.selector, m));
        midnightAdapter.fundCallback(callback, m, FUND_AMOUNT);
    }

    function test_WhenLoanTokenNotVaultAsset() external {
        MarketParams memory p = fundingParams;
        p.loanToken = address(usdt);
        Id m = Id.wrap(keccak256(abi.encode(p)));
        mockMorpho.setMarketParams(m, p);
        _allowMarket(users.vault, m);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.LoanTokenNotVaultAsset.selector, address(usdt)));
        midnightAdapter.fundCallback(callback, m, FUND_AMOUNT);
    }

    function test_GivenCapNotSet() external {
        vm.prank(users.owner);
        midnightRegistry.setCap(users.vault, 0);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.ExposureCapExceeded.selector, FUND_AMOUNT, 0));
        midnightAdapter.fundCallback(callback, fundingId, FUND_AMOUNT);
    }

    function test_WhenFundingExceedsExposureCap() external {
        _fundCallback(FUND_AMOUNT);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.ExposureCapExceeded.selector, FUND_AMOUNT + CAP, CAP));
        midnightAdapter.fundCallback(callback, fundingId, CAP);
    }

    function test_WhenFundingReachesExposureCapExactly() external {
        _fundCallback(FUND_AMOUNT);
        _fundCallback(CAP - FUND_AMOUNT);

        assertEq(midnightAdapter.deployedAssets(users.vault), CAP, "deployedAssets");
    }

    function test_GivenMorphoReturnsZeroShareDelta() external {
        mockMorpho.setSkipShareCredit(true);

        vm.prank(users.vault);
        vm.expectRevert(IYoMidnightAdapter.NoShareDelta.selector);
        midnightAdapter.fundCallback(callback, fundingId, FUND_AMOUNT);
    }

    function test_GivenMorphoReturnsPositiveShareDelta() external {
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.expectEmit(address(midnightAdapter));
        emit YoMidnightAdapter.MidnightCallbackAction(
            users.vault,
            callback,
            fundingId,
            YoAdapterBase.AdapterDirection.Deposit,
            FUND_AMOUNT
        );

        vm.prank(users.vault);
        (uint256 assetsSupplied, uint256 sharesSupplied) =
            midnightAdapter.fundCallback(callback, fundingId, FUND_AMOUNT);

        assertEq(assetsSupplied, FUND_AMOUNT, "assetsSupplied");
        assertGt(sharesSupplied, 0, "sharesSupplied");
        assertEq(usdc.balanceOf(users.vault), vaultBefore - FUND_AMOUNT, "vault USDC delta");
        assertEq(mockMorpho.position(fundingId, callback).supplyShares, FUND_AMOUNT, "callback shares");
        assertEq(mockMorpho.position(fundingId, users.vault).supplyShares, 0, "vault shares");
        assertEq(midnightAdapter.deployedAssets(users.vault), FUND_AMOUNT, "deployedAssets");
        assertZeroBalance(address(usdc), address(midnightAdapter));
        assertZeroAllowance(address(usdc), address(midnightAdapter), address(mockMorpho));
    }
}
