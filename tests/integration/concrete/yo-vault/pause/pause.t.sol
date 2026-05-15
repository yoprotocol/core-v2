// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract PauseIntegrationConcreteTest is YoVaultBase_Test {
    function test_RevertWhen_CallerNotAuthorized() external {
        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        yoVault.pause();
    }

    function test_WhenAuthorized_SetsPaused() external {
        vm.prank(users.owner);
        yoVault.pause();
        assertTrue(yoVault.paused());
    }

    function test_RevertGiven_AlreadyPaused() external {
        vm.prank(users.owner);
        yoVault.pause();

        vm.prank(users.owner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        yoVault.pause();
    }
}
