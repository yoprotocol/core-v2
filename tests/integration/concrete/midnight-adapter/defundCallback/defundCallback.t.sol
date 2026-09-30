// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";
import { Id } from "src/interfaces/IMorpho.sol";
import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";

import { MockBlueBuyCallback } from "../../../../mocks/MockMidnight.sol";
import { MidnightAdapter_Integration_Concrete_Test } from "../MidnightAdapter.t.sol";

contract DefundCallback_Integration_Concrete_Test is MidnightAdapter_Integration_Concrete_Test {
    function setUp() public override {
        MidnightAdapter_Integration_Concrete_Test.setUp();
        _fundCallback(FUND_AMOUNT);
    }

    function test_WhenAssetsZero() external whenCallerVault {
        vm.expectRevert(IYoMidnightAdapter.InvalidAmount.selector);
        midnightAdapter.defundCallback(callback, fundingId, 0);
    }

    function test_WhenCallbackOwnedByAnotherVault() external whenCallerVault {
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.InvalidCallback.selector, eveCallback));
        midnightAdapter.defundCallback(eveCallback, fundingId, FUND_AMOUNT);
    }

    function test_GivenIdToMarketParamsReturnsZeroLoanToken() external whenCallerVault {
        Id m = Id.wrap(keccak256("UNKNOWN_MARKET"));
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.UnknownMarket.selector, m));
        midnightAdapter.defundCallback(callback, m, FUND_AMOUNT);
    }

    function test_GivenCallbackHasNotAuthorizedAdapterOnMorpho() external {
        vm.prank(users.vault);
        MockBlueBuyCallback(callback).setAuthorization(address(midnightAdapter), false);

        vm.prank(users.vault);
        vm.expectRevert(bytes("not authorized"));
        midnightAdapter.defundCallback(callback, fundingId, FUND_AMOUNT);
    }

    function test_GivenFundingMarketRemovedFromAllowlist() external {
        vm.prank(users.owner);
        marketRegistry.setAllowed(users.vault, fundingId, false);
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        midnightAdapter.defundCallback(callback, fundingId, FUND_AMOUNT);

        assertEq(usdc.balanceOf(users.vault), vaultBefore + FUND_AMOUNT, "vault USDC delta");
    }

    function test_GivenFundingMarketAllowlisted() external {
        uint256 part = FUND_AMOUNT / 4;
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.expectEmit(address(midnightAdapter));
        emit YoMidnightAdapter.MidnightCallbackAction(
            users.vault,
            callback,
            fundingId,
            YoAdapterBase.AdapterDirection.Withdraw,
            part
        );

        vm.prank(users.vault);
        (uint256 assetsWithdrawn, uint256 sharesBurned) = midnightAdapter.defundCallback(callback, fundingId, part);

        assertEq(assetsWithdrawn, part, "assetsWithdrawn");
        assertGt(sharesBurned, 0, "sharesBurned");
        assertEq(mockMorpho.position(fundingId, callback).supplyShares, FUND_AMOUNT - part, "callback shares");
        assertEq(usdc.balanceOf(users.vault), vaultBefore + part, "vault USDC delta");
        assertZeroBalance(address(usdc), address(midnightAdapter));
    }
}
