// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "src/interfaces/IMorpho.sol";
import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";

import { MidnightAdapter_Integration_Concrete_Test } from "../MidnightAdapter.t.sol";

contract DefundCallbackAll_Integration_Concrete_Test is MidnightAdapter_Integration_Concrete_Test {
    function test_WhenCallbackOwnedByAnotherVault() external whenCallerVault {
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.InvalidCallback.selector, eveCallback));
        midnightAdapter.defundCallbackAll(eveCallback, fundingId);
    }

    function test_GivenIdToMarketParamsReturnsZeroLoanToken() external whenCallerVault {
        Id m = Id.wrap(keccak256("UNKNOWN_MARKET"));
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.UnknownMarket.selector, m));
        midnightAdapter.defundCallbackAll(callback, m);
    }

    function test_GivenCallbackHasNoSupplyPosition() external whenCallerVault {
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.NoPosition.selector, fundingId));
        midnightAdapter.defundCallbackAll(callback, fundingId);
    }

    function test_GivenCallbackHasSupplyPosition() external {
        _fundCallback(FUND_AMOUNT);
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        (uint256 assetsWithdrawn, uint256 sharesBurned) = midnightAdapter.defundCallbackAll(callback, fundingId);

        assertEq(assetsWithdrawn, FUND_AMOUNT, "assetsWithdrawn");
        assertEq(sharesBurned, FUND_AMOUNT, "sharesBurned");
        assertEq(mockMorpho.position(fundingId, callback).supplyShares, 0, "callback shares");
        assertEq(usdc.balanceOf(users.vault), vaultBefore + FUND_AMOUNT, "vault USDC delta");
    }
}
