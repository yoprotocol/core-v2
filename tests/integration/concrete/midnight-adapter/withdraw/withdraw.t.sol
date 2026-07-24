// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";
import { Market } from "src/interfaces/IMidnight.sol";
import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";

import { Midnight_Integration_Shared } from "../../../MidnightIntegration.t.sol";

contract Withdraw_Integration_Concrete_Test is Midnight_Integration_Shared {
    uint256 internal constant UNITS = 4000e6;

    function _seed() internal {
        bytes32 id = marketId();
        mockMidnight.setCredit(id, users.vault, uint128(TAKE_UNITS));
        mockMidnight.setWithdrawable(id, uint128(TAKE_UNITS));
    }

    function test_RevertWhen_UnitsZero() external whenCallerVault whenMarketAllowed {
        Market memory m = market();
        vm.expectRevert(IYoMidnightAdapter.InvalidAmount.selector);
        midnightAdapter.withdraw(m, 0);
    }

    function test_RevertWhen_MarketNotAllowed() external {
        bytes32 id = marketId();
        Market memory m = market();

        vm.prank(users.owner);
        midnightRegistry.setAllowed(users.vault, id, false, 0);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.MarketNotAllowed.selector, id));
        midnightAdapter.withdraw(m, UNITS);
    }

    function test_RevertWhen_AdapterNotAuthorized() external whenMarketAllowed {
        _seed();
        Market memory m = market();

        vm.prank(users.vault);
        mockMidnight.setIsAuthorized(address(midnightAdapter), false, users.vault);

        vm.prank(users.vault);
        vm.expectRevert(bytes("unauthorized"));
        midnightAdapter.withdraw(m, UNITS);
    }

    function test_WhenAuthorizedAndFunded_Redeems() external whenMarketAllowed {
        _seed();
        Market memory m = market();
        bytes32 id = marketId();
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.expectEmit(true, true, false, true, address(midnightAdapter));
        emit YoMidnightAdapter.MidnightMarketAction(
            users.vault,
            id,
            YoAdapterBase.AdapterDirection.Withdraw,
            UNITS,
            UNITS
        );
        vm.prank(users.vault);
        midnightAdapter.withdraw(m, UNITS);

        assertEq(usdc.balanceOf(users.vault), vaultBefore + UNITS, "vault received loan token");
        assertEq(mockMidnight.credit(id, users.vault), TAKE_UNITS - UNITS, "credit burned");
    }
}
