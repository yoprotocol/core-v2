// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";
import { Errors } from "src/libraries/Errors.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract UpdateFeeIntegrationConcreteTest is YoVaultBase_Test {
    uint256 internal constant MAX_FEE = 1e17;

    function test_WhenOwner_UpdatesDepositFee() external {
        vm.prank(users.owner);
        yoVault.updateDepositFee(1e16);
        assertEq(yoVault.feeOnDeposit(), 1e16);
    }

    function test_RevertWhen_DepositFeeAtMaxThreshold() external {
        vm.prank(users.owner);
        vm.expectRevert(Errors.InvalidFee.selector);
        yoVault.updateDepositFee(MAX_FEE);
    }

    function test_RevertWhen_UpdateDepositFeeUnauthorized() external {
        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        yoVault.updateDepositFee(MAX_FEE);
    }

    function test_WhenOwner_UpdatesWithdrawFee() external {
        vm.prank(users.owner);
        yoVault.updateWithdrawFee(1e16);
        assertEq(yoVault.feeOnWithdraw(), 1e16);
    }

    function test_RevertWhen_WithdrawFeeAtMaxThreshold() external {
        vm.prank(users.owner);
        vm.expectRevert(Errors.InvalidFee.selector);
        yoVault.updateWithdrawFee(MAX_FEE);
    }

    function test_RevertWhen_UpdateWithdrawFeeUnauthorized() external {
        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        yoVault.updateWithdrawFee(MAX_FEE);
    }
}
