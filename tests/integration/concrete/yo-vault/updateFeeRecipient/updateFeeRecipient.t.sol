// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract UpdateFeeRecipientIntegrationConcreteTest is YoVaultBase_Test {
    function test_WhenOwner_UpdatesFeeRecipient() external {
        vm.prank(users.owner);
        yoVault.updateFeeRecipient(users.bob);
        assertEq(yoVault.feeRecipient(), users.bob);
    }

    function test_RevertWhen_Unauthorized() external {
        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        yoVault.updateFeeRecipient(users.bob);
    }
}
