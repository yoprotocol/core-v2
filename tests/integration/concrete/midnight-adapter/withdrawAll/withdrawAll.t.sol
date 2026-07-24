// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";
import { Market } from "src/interfaces/IMidnight.sol";
import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";

import { Midnight_Integration_Shared } from "../../../MidnightIntegration.t.sol";

contract WithdrawAll_Integration_Concrete_Test is Midnight_Integration_Shared {
    function test_RevertWhen_MarketNotAllowed() external {
        bytes32 id = marketId();
        Market memory m = market();

        vm.prank(users.owner);
        midnightRegistry.setAllowed(users.vault, id, false, 0);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMidnightAdapter.MarketNotAllowed.selector, id));
        midnightAdapter.withdrawAll(m);
    }

    function test_RevertWhen_NoPosition() external whenMarketAllowed {
        // No credit and nothing withdrawable → min is zero.
        Market memory m = market();
        vm.prank(users.vault);
        vm.expectRevert(IYoMidnightAdapter.NoPosition.selector);
        midnightAdapter.withdrawAll(m);
    }

    function test_WhenWithdrawableBelowCredit_RedeemsWithdrawable() external whenMarketAllowed {
        bytes32 id = marketId();
        mockMidnight.setCredit(id, users.vault, uint128(TAKE_UNITS));
        mockMidnight.setWithdrawable(id, 4000e6);

        Market memory m = market();
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 units = midnightAdapter.withdrawAll(m);

        assertEq(units, 4000e6, "redeemed only withdrawable");
        assertEq(usdc.balanceOf(users.vault), vaultBefore + 4000e6, "vault received withdrawable");
        assertEq(mockMidnight.credit(id, users.vault), TAKE_UNITS - 4000e6, "credit partially burned");
    }

    function test_WhenWithdrawableAtLeastCredit_RedeemsFullCredit() external whenMarketAllowed {
        bytes32 id = marketId();
        mockMidnight.setCredit(id, users.vault, uint128(TAKE_UNITS));
        mockMidnight.setWithdrawable(id, uint128(TAKE_UNITS + 5000e6));

        Market memory m = market();
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.expectEmit(true, true, false, true, address(midnightAdapter));
        emit YoMidnightAdapter.MidnightMarketAction(
            users.vault,
            id,
            YoAdapterBase.AdapterDirection.Withdraw,
            TAKE_UNITS,
            TAKE_UNITS
        );
        vm.prank(users.vault);
        uint256 units = midnightAdapter.withdrawAll(m);

        assertEq(units, TAKE_UNITS, "redeemed full credit");
        assertEq(usdc.balanceOf(users.vault), vaultBefore + TAKE_UNITS, "vault received full credit");
        assertEq(mockMidnight.credit(id, users.vault), 0, "credit fully burned");
    }
}
