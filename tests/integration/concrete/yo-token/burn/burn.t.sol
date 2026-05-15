// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";

import { YoTokenBase_Test } from "../YoTokenBase.t.sol";

contract BurnIntegrationConcreteTest is YoTokenBase_Test {
    uint256 internal constant BURN_AMOUNT = 50e18;

    function test_WhenOwnerBurns_Succeeds() external {
        uint256 supplyBefore = token.totalSupply();
        uint256 balBefore = token.balanceOf(users.owner);

        vm.prank(users.owner);
        token.burn(BURN_AMOUNT);

        assertEq(token.totalSupply(), supplyBefore - BURN_AMOUNT);
        assertEq(token.balanceOf(users.owner), balBefore - BURN_AMOUNT);
    }

    function test_RevertWhen_NonOwnerBurnsWithoutGrant() external {
        // Send some tokens to bob.
        vm.prank(users.owner);
        token.transfer(users.bob, BURN_AMOUNT);

        vm.prank(users.bob);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        token.burn(1e18);
    }
}
