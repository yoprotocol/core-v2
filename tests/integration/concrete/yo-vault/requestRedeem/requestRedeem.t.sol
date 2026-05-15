// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Errors } from "src/libraries/Errors.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract RequestRedeemIntegrationConcreteTest is YoVaultBase_Test {
    uint256 internal constant AMOUNT = 100e6;

    function setUp() public override {
        super.setUp();
        vm.prank(users.alice);
        yoVault.deposit(AMOUNT, users.alice);
    }

    function test_WhenInstantRequest_Succeeds() external {
        uint256 aliceShares = yoVault.balanceOf(users.alice);
        assertEq(aliceShares, AMOUNT);
        assertEq(yoVault.totalAssets(), AMOUNT);

        vm.prank(users.alice);
        yoVault.requestRedeem(aliceShares, users.alice, users.alice);

        assertEq(yoVault.balanceOf(users.alice), 0);
        assertEq(yoVault.totalAssets(), 0);
    }

    function test_RevertWhen_ZeroReceiver() external {
        uint256 aliceShares = yoVault.balanceOf(users.alice);

        vm.prank(users.alice);
        vm.expectRevert(Errors.ZeroReceiver.selector);
        yoVault.requestRedeem(aliceShares, address(0), users.alice);
    }

    function test_RevertWhen_SharesAmountZero() external {
        vm.prank(users.alice);
        vm.expectRevert(Errors.SharesAmountZero.selector);
        yoVault.requestRedeem(0, users.alice, users.alice);
    }

    function test_RevertWhen_NotSharesOwner() external {
        uint256 aliceShares = yoVault.balanceOf(users.alice);

        vm.prank(users.alice);
        vm.expectRevert(Errors.NotSharesOwner.selector);
        yoVault.requestRedeem(aliceShares, users.alice, users.bob);
    }

    function test_RevertWhen_InsufficientShares() external {
        uint256 aliceShares = yoVault.balanceOf(users.alice);

        vm.prank(users.alice);
        vm.expectRevert(Errors.InsufficientShares.selector);
        yoVault.requestRedeem(aliceShares + 1, users.alice, users.alice);
    }
}
