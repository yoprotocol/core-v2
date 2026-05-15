// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";
import { IYoApprovalRegistry } from "src/interfaces/IYoApprovalRegistry.sol";
import { IYoVault } from "src/interfaces/IYoVault.sol";
import { YoApprovalRegistry } from "src/registries/YoApprovalRegistry.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract SetApprovalRegistryIntegrationConcreteTest is YoVaultBase_Test {
    function test_RevertWhen_CallerNotAuthorized() external {
        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        yoVault.setApprovalRegistry(approvalRegistry);
    }

    function test_GivenNoPriorRegistry_SetsAndEmits() external {
        // Wipe the registry set in setUp to simulate "no prior".
        vm.prank(users.owner);
        yoVault.setApprovalRegistry(IYoApprovalRegistry(address(0)));
        assertEq(address(yoVault.approvalRegistry()), address(0));

        YoApprovalRegistry fresh = new YoApprovalRegistry(users.owner);

        vm.expectEmit(true, true, true, true, address(yoVault));
        emit IYoVault.ApprovalRegistrySet(address(0), address(fresh));

        vm.prank(users.owner);
        yoVault.setApprovalRegistry(fresh);

        assertEq(address(yoVault.approvalRegistry()), address(fresh));
    }

    function test_GivenPriorRegistry_ReplacesAndEmits() external {
        // Initial registry was set in YoVaultBase.setUp().
        address previous = address(yoVault.approvalRegistry());
        assertEq(previous, address(approvalRegistry));

        YoApprovalRegistry next = new YoApprovalRegistry(users.owner);

        vm.expectEmit(true, true, true, true, address(yoVault));
        emit IYoVault.ApprovalRegistrySet(previous, address(next));

        vm.prank(users.owner);
        yoVault.setApprovalRegistry(next);

        assertEq(address(yoVault.approvalRegistry()), address(next));
    }
}
