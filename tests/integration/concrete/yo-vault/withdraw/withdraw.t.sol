// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Errors } from "src/libraries/Errors.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract WithdrawIntegrationConcreteTest is YoVaultBase_Test {
    function test_RevertAlways_UseRequestRedeem() external {
        vm.prank(users.alice);
        vm.expectRevert(Errors.UseRequestRedeem.selector);
        yoVault.withdraw(100e6, users.alice, users.alice);
    }
}
