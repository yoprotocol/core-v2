// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Errors } from "src/libraries/Errors.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract FulfillRedeemIntegrationConcreteTest is YoVaultBase_Test {
    uint256 internal constant AMOUNT = 100e6;
    uint256 internal aliceShares;

    function setUp() public override {
        super.setUp();

        // Alice deposits, owner pulls liquidity, alice queues a redeem.
        vm.prank(users.alice);
        yoVault.deposit(AMOUNT, users.alice);

        _moveAssetsFromVault(AMOUNT);

        aliceShares = yoVault.balanceOf(users.alice);
        vm.prank(users.alice);
        yoVault.requestRedeem(aliceShares, users.alice, users.alice);

        // Owner returns assets to the vault so fulfill can settle.
        vm.roll(block.number + 1);
        vm.prank(users.owner);
        usdc.transfer(address(yoVault), AMOUNT);
    }

    function test_WhenFulfillFull_ClearsPending() external {
        uint256 totalPendingBefore = yoVault.totalPendingAssets();
        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);

        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, pendingShares, pendingAssets);

        (uint256 pendingAssetsAfter, uint256 pendingSharesAfter) = yoVault.pendingRedeemRequest(users.alice);

        assertEq(yoVault.totalPendingAssets(), totalPendingBefore - pendingAssets);
        assertEq(pendingAssetsAfter, 0);
        assertEq(pendingSharesAfter, 0);
    }

    function test_RevertWhen_FulfillAlreadyDrained() external {
        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);

        vm.startPrank(users.owner);
        yoVault.fulfillRedeem(users.alice, pendingShares, pendingAssets);

        vm.expectRevert(Errors.InvalidSharesAmount.selector);
        yoVault.fulfillRedeem(users.alice, pendingShares, pendingAssets);
        vm.stopPrank();
    }

    function test_RevertWhen_SharesArgExceedsPending() external {
        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);

        vm.prank(users.owner);
        vm.expectRevert(Errors.InvalidSharesAmount.selector);
        yoVault.fulfillRedeem(users.alice, pendingShares + 1, pendingAssets);
    }

    function test_RevertWhen_AssetsArgExceedsPending() external {
        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);

        vm.prank(users.owner);
        vm.expectRevert(Errors.InvalidAssetsAmount.selector);
        yoVault.fulfillRedeem(users.alice, pendingShares, pendingAssets + 1);
    }

    function test_RevertWhen_VaultMissingAssets() external {
        _moveAssetsFromVault(AMOUNT);
        vm.roll(block.number + 1);

        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);

        vm.prank(users.owner);
        vm.expectRevert();
        yoVault.fulfillRedeem(users.alice, pendingShares, pendingAssets);
    }
}
