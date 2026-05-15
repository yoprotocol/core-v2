// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoVaultBase_Test } from "../../concrete/yo-vault/YoVaultBase.t.sol";

contract QueueLifecycle_YoVault_Integration_Fuzz_Test is YoVaultBase_Test {
    /// @dev Async queue invariants for partial fulfill:
    ///        - totalPendingAssets decreases by exactly `fulfillAssets`
    ///        - per-user pending decreases by exactly `(fulfillShares, fulfillAssets)`
    function testFuzz_PartialFulfill_DecreasesPendingExactly(uint256 deposit, uint256 fulfillShares) external {
        deposit = bound(deposit, 100, 500_000e6);

        vm.prank(users.alice);
        yoVault.deposit(deposit, users.alice);

        _moveAssetsFromVault(deposit);

        uint256 aliceShares = yoVault.balanceOf(users.alice);
        vm.prank(users.alice);
        yoVault.requestRedeem(aliceShares, users.alice, users.alice);

        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);
        // bound fulfill within what's pending
        fulfillShares = bound(fulfillShares, 1, pendingShares);
        // assets must scale to whatever the operator chooses up to pendingAssets — pick a value
        // that respects the pendingAssets cap.
        uint256 fulfillAssets = (pendingAssets * fulfillShares) / pendingShares;
        fulfillAssets = bound(fulfillAssets, 1, pendingAssets);

        // Re-fund vault so fulfill can settle.
        vm.prank(users.owner);
        usdc.transfer(address(yoVault), fulfillAssets);

        uint256 totalPendingBefore = yoVault.totalPendingAssets();
        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, fulfillShares, fulfillAssets);

        (uint256 pendingAssetsAfter, uint256 pendingSharesAfter) = yoVault.pendingRedeemRequest(users.alice);
        assertEq(yoVault.totalPendingAssets(), totalPendingBefore - fulfillAssets, "totalPending delta");
        assertEq(pendingAssetsAfter, pendingAssets - fulfillAssets, "alice pending assets delta");
        assertEq(pendingSharesAfter, pendingShares - fulfillShares, "alice pending shares delta");
    }

    /// @dev cancelRedeem returns escrowed shares to the receiver exactly.
    function testFuzz_PartialCancel_ReturnsSharesExactly(uint256 deposit, uint256 cancelShares) external {
        deposit = bound(deposit, 100, 500_000e6);

        vm.prank(users.alice);
        yoVault.deposit(deposit, users.alice);
        _moveAssetsFromVault(deposit);

        uint256 aliceShares = yoVault.balanceOf(users.alice);
        vm.prank(users.alice);
        yoVault.requestRedeem(aliceShares, users.alice, users.alice);

        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);
        cancelShares = bound(cancelShares, 1, pendingShares);
        uint256 cancelAssets = (pendingAssets * cancelShares) / pendingShares;
        cancelAssets = bound(cancelAssets, 1, pendingAssets);

        uint256 aliceSharesBefore = yoVault.balanceOf(users.alice);

        vm.prank(users.owner);
        yoVault.cancelRedeem(users.alice, cancelShares, cancelAssets);

        assertEq(yoVault.balanceOf(users.alice), aliceSharesBefore + cancelShares, "alice gets shares back");
    }
}
