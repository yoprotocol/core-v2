// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract UnpauseIntegrationConcreteTest is YoVaultBase_Test {
    function setUp() public override {
        super.setUp();
        vm.prank(users.owner);
        yoVault.pause();
    }

    function test_RevertWhen_CallerNotAuthorized() external {
        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        yoVault.unpause();
    }

    function test_WhenAuthorized_ClearsPaused() external {
        vm.prank(users.owner);
        yoVault.unpause();
        assertFalse(yoVault.paused());
    }

    function test_RevertGiven_NotPaused() external {
        vm.prank(users.owner);
        yoVault.unpause();

        vm.prank(users.owner);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        yoVault.unpause();
    }
}
