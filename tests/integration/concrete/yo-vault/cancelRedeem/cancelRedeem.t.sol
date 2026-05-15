// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Errors } from "src/libraries/Errors.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract CancelRedeemIntegrationConcreteTest is YoVaultBase_Test {
    uint256 internal constant AMOUNT = 100e6;
    uint256 internal aliceShares;

    function setUp() public override {
        super.setUp();

        vm.prank(users.alice);
        yoVault.deposit(AMOUNT, users.alice);

        _moveAssetsFromVault(AMOUNT);

        aliceShares = yoVault.balanceOf(users.alice);
        vm.prank(users.alice);
        yoVault.requestRedeem(aliceShares, users.alice, users.alice);

        vm.roll(block.number + 1);
        vm.prank(users.owner);
        usdc.transfer(address(yoVault), AMOUNT);
    }

    function test_WhenCancelFull_RestoresShares() external {
        uint256 totalPendingBefore = yoVault.totalPendingAssets();
        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);
        uint256 aliceSharesBefore = yoVault.balanceOf(users.alice);

        vm.prank(users.owner);
        yoVault.cancelRedeem(users.alice, pendingShares, pendingAssets);

        (uint256 pendingAssetsAfter, uint256 pendingSharesAfter) = yoVault.pendingRedeemRequest(users.alice);

        assertEq(yoVault.totalPendingAssets(), totalPendingBefore - pendingShares);
        assertEq(pendingAssetsAfter, 0);
        assertEq(pendingSharesAfter, 0);
        assertEq(yoVault.balanceOf(users.alice), aliceSharesBefore + pendingShares);
    }

    function test_RevertWhen_SharesArgExceedsPending() external {
        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);

        vm.prank(users.owner);
        vm.expectRevert(Errors.InvalidSharesAmount.selector);
        yoVault.cancelRedeem(users.alice, pendingShares + 1, pendingAssets);
    }

    function test_RevertWhen_AssetsArgExceedsPending() external {
        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);

        vm.prank(users.owner);
        vm.expectRevert(Errors.InvalidAssetsAmount.selector);
        yoVault.cancelRedeem(users.alice, pendingShares, pendingAssets + 1);
    }

    function test_RevertWhen_DoubleCancel() external {
        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);

        vm.startPrank(users.owner);
        yoVault.cancelRedeem(users.alice, pendingShares, pendingAssets);

        vm.expectRevert(Errors.InvalidSharesAmount.selector);
        yoVault.cancelRedeem(users.alice, pendingShares, pendingAssets);
        vm.stopPrank();
    }
}
