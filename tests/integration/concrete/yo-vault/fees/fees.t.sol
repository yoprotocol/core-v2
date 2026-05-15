// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract FeesIntegrationConcreteTest is YoVaultBase_Test {
    uint256 internal constant DEPOSIT_AMOUNT = 115e6;
    uint256 internal constant DEPOSIT_FEE = 1e16;
    uint256 internal constant WITHDRAW_FEE = 9e16;

    address internal recipient;

    function setUp() public override {
        super.setUp();

        recipient = users.bob;

        vm.startPrank(users.owner);
        yoVault.updateDepositFee(DEPOSIT_FEE);
        yoVault.updateWithdrawFee(WITHDRAW_FEE);
        yoVault.updateFeeRecipient(recipient);
        vm.stopPrank();
    }

    function test_DepositAndRedeem_BothFees() external {
        vm.startPrank(users.alice);

        uint256 aliceAssetsBefore = usdc.balanceOf(users.alice);
        uint256 vaultAssetsBefore = usdc.balanceOf(address(yoVault));
        uint256 recipientBefore = usdc.balanceOf(recipient);

        uint256 depositFeeAmount = yoVault.exposed_feeOnTotal(DEPOSIT_AMOUNT, DEPOSIT_FEE);
        uint256 previewDeposit = yoVault.previewDeposit(DEPOSIT_AMOUNT);
        yoVault.deposit(DEPOSIT_AMOUNT, users.alice);

        uint256 aliceAssetsAfterDeposit = usdc.balanceOf(users.alice);
        uint256 aliceSharesAfterDeposit = yoVault.balanceOf(users.alice);

        assertEq(aliceAssetsAfterDeposit, aliceAssetsBefore - DEPOSIT_AMOUNT);
        assertEq(aliceSharesAfterDeposit, previewDeposit);
        assertEq(aliceSharesAfterDeposit, DEPOSIT_AMOUNT - depositFeeAmount);
        assertEq(usdc.balanceOf(address(yoVault)), vaultAssetsBefore + DEPOSIT_AMOUNT - depositFeeAmount);
        assertEq(usdc.balanceOf(recipient), recipientBefore + depositFeeAmount);

        uint256 redeemFeeAmount = yoVault.exposed_feeOnTotal(aliceSharesAfterDeposit, WITHDRAW_FEE);
        uint256 previewRedeem = yoVault.previewRedeem(aliceSharesAfterDeposit);
        yoVault.requestRedeem(aliceSharesAfterDeposit, users.alice, users.alice);

        uint256 aliceAssetsAfterRedeem = usdc.balanceOf(users.alice);

        assertEq(aliceAssetsAfterRedeem, aliceAssetsAfterDeposit + (aliceSharesAfterDeposit - redeemFeeAmount));
        assertEq(aliceAssetsAfterRedeem, aliceAssetsAfterDeposit + previewRedeem);
        assertEq(yoVault.balanceOf(users.alice), 0);
        assertEq(usdc.balanceOf(recipient), recipientBefore + depositFeeAmount + redeemFeeAmount);
    }

    function test_DepositAndRedeem_OnlyDepositFee() external {
        vm.prank(users.owner);
        yoVault.updateWithdrawFee(0);

        vm.startPrank(users.alice);

        uint256 recipientBefore = usdc.balanceOf(recipient);
        uint256 depositFeeAmount = yoVault.exposed_feeOnTotal(DEPOSIT_AMOUNT, DEPOSIT_FEE);

        yoVault.deposit(DEPOSIT_AMOUNT, users.alice);

        uint256 aliceShares = yoVault.balanceOf(users.alice);
        uint256 recipientAfterDeposit = usdc.balanceOf(recipient);

        assertEq(aliceShares, DEPOSIT_AMOUNT - depositFeeAmount);
        assertEq(recipientAfterDeposit, recipientBefore + depositFeeAmount);

        yoVault.requestRedeem(aliceShares, users.alice, users.alice);

        // Withdraw fee = 0, recipient unchanged after redeem.
        assertEq(yoVault.balanceOf(users.alice), 0);
        assertEq(usdc.balanceOf(recipient), recipientAfterDeposit);
    }

    function test_DepositAndRedeem_OnlyWithdrawFee() external {
        vm.prank(users.owner);
        yoVault.updateDepositFee(0);

        vm.startPrank(users.alice);

        uint256 recipientBefore = usdc.balanceOf(recipient);

        yoVault.deposit(DEPOSIT_AMOUNT, users.alice);

        uint256 aliceShares = yoVault.balanceOf(users.alice);
        // 1:1 with no deposit fee.
        assertEq(aliceShares, DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(recipient), recipientBefore);

        uint256 redeemFeeAmount = yoVault.exposed_feeOnTotal(aliceShares, WITHDRAW_FEE);
        yoVault.requestRedeem(aliceShares, users.alice, users.alice);

        assertEq(yoVault.balanceOf(users.alice), 0);
        assertEq(usdc.balanceOf(recipient), recipientBefore + redeemFeeAmount);
    }

    function test_MintAndRedeem_BothFees() external {
        vm.startPrank(users.alice);

        uint256 aliceAssetsBefore = usdc.balanceOf(users.alice);
        uint256 recipientBefore = usdc.balanceOf(recipient);

        uint256 depositFeeAmount = yoVault.exposed_feeOnRaw(DEPOSIT_AMOUNT, DEPOSIT_FEE);
        uint256 previewMint = yoVault.previewMint(DEPOSIT_AMOUNT);
        yoVault.mint(DEPOSIT_AMOUNT, users.alice);

        uint256 aliceAssetsAfterDeposit = usdc.balanceOf(users.alice);
        uint256 aliceSharesAfterDeposit = yoVault.balanceOf(users.alice);

        // `mint` pulls (assets + raw-fee) and credits exactly `DEPOSIT_AMOUNT` shares.
        assertEq(aliceAssetsAfterDeposit, aliceAssetsBefore - (DEPOSIT_AMOUNT + depositFeeAmount));
        assertEq(aliceAssetsAfterDeposit, aliceAssetsBefore - previewMint);
        assertEq(aliceSharesAfterDeposit, DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(recipient), recipientBefore + depositFeeAmount);

        uint256 redeemFeeAmount = yoVault.exposed_feeOnTotal(aliceSharesAfterDeposit, WITHDRAW_FEE);
        yoVault.requestRedeem(aliceSharesAfterDeposit, users.alice, users.alice);

        assertEq(yoVault.balanceOf(users.alice), 0);
        assertEq(usdc.balanceOf(users.alice), aliceAssetsAfterDeposit + (aliceSharesAfterDeposit - redeemFeeAmount));
        assertEq(usdc.balanceOf(recipient), recipientBefore + depositFeeAmount + redeemFeeAmount);
    }

    function test_AsyncRedeem_BothFees() external {
        uint256 depositFeeAmount = yoVault.exposed_feeOnTotal(DEPOSIT_AMOUNT, DEPOSIT_FEE);
        uint256 netDeposit = DEPOSIT_AMOUNT - depositFeeAmount;
        uint256 recipientBefore = usdc.balanceOf(recipient);

        vm.prank(users.alice);
        yoVault.deposit(DEPOSIT_AMOUNT, users.alice);

        // Owner pulls all of the depositable liquidity so redeem must queue.
        _moveAssetsFromVault(netDeposit);

        uint256 aliceShares = yoVault.balanceOf(users.alice);
        uint256 totalPendingBefore = yoVault.totalPendingAssets();
        uint256 redeemFeeAmount = yoVault.exposed_feeOnTotal(aliceShares, WITHDRAW_FEE);

        vm.prank(users.alice);
        yoVault.requestRedeem(aliceShares, users.alice, users.alice);

        vm.roll(block.number + 1);
        vm.prank(users.owner);
        usdc.transfer(address(yoVault), netDeposit);

        assertEq(yoVault.totalPendingAssets(), totalPendingBefore + netDeposit);
        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);
        assertEq(pendingAssets, netDeposit);
        assertEq(pendingShares, aliceShares);

        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, pendingShares, pendingAssets);

        (uint256 pendingAssetsAfter, uint256 pendingSharesAfter) = yoVault.pendingRedeemRequest(users.alice);

        assertEq(yoVault.totalPendingAssets(), 0);
        assertEq(pendingAssetsAfter, 0);
        assertEq(pendingSharesAfter, 0);
        assertEq(yoVault.balanceOf(users.alice), 0);
        assertEq(yoVault.totalAssets(), 0);
        assertEq(yoVault.balanceOf(address(yoVault)), 0);
        assertEq(usdc.balanceOf(recipient), recipientBefore + redeemFeeAmount + depositFeeAmount);
    }
}
