// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract TransferOwnershipIntegrationConcreteTest is YoVaultBase_Test {
    function test_RevertWhen_CallerNotAuthorized() external {
        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        yoVault.transferOwnership(users.bob);
    }

    function test_WhenAuthorized_UpdatesOwnerAndEmits() external {
        vm.expectEmit(true, true, true, true, address(yoVault));
        emit AuthUpgradeable.OwnershipTransferred(users.owner, users.bob);

        vm.prank(users.owner);
        yoVault.transferOwnership(users.bob);

        assertEq(yoVault.owner(), users.bob);
    }
}
