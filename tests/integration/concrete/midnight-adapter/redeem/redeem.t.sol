// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { stdError } from "forge-std/src/StdError.sol";

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";

import { MidnightAdapter_Integration_Concrete_Test } from "../MidnightAdapter.t.sol";

contract Redeem_Integration_Concrete_Test is MidnightAdapter_Integration_Concrete_Test {
    uint256 internal constant CREDIT = 1000e6;

    function setUp() public override {
        MidnightAdapter_Integration_Concrete_Test.setUp();
        mockMidnight.setCredit(users.vault, address(usdc), CREDIT);
        usdc.mint(address(mockMidnight), CREDIT);
    }

    function test_WhenUnitsZero() external whenCallerVault {
        vm.expectRevert(IYoMidnightAdapter.InvalidAmount.selector);
        midnightAdapter.redeem(_market(block.timestamp + TERM), 0);
    }

    function test_GivenAdapterNotAuthorizedOnMidnight() external whenCallerVault {
        mockMidnight.setIsAuthorized(address(midnightAdapter), false, users.vault);

        vm.expectRevert(bytes("unauthorized"));
        midnightAdapter.redeem(_market(block.timestamp + TERM), CREDIT);
    }

    function test_GivenUnitsExceedVaultCredit() external whenCallerVault {
        vm.expectRevert(stdError.arithmeticError);
        midnightAdapter.redeem(_market(block.timestamp + TERM), CREDIT + 1);
    }

    function test_GivenUnitsWithinVaultCredit() external whenCallerVault {
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.expectEmit(address(midnightAdapter));
        emit YoAdapterBase.AdapterAction(
            users.vault,
            address(mockMidnight),
            address(usdc),
            YoAdapterBase.AdapterDirection.Withdraw,
            CREDIT
        );

        midnightAdapter.redeem(_market(block.timestamp + TERM), CREDIT);

        assertEq(mockMidnight.credit(users.vault, address(usdc)), 0, "credit");
        assertEq(usdc.balanceOf(users.vault), vaultBefore + CREDIT, "vault USDC delta");
    }
}
