// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Errors } from "src/libraries/Errors.sol";

import { YoVaultBase_Test } from "../../concrete/yo-vault/YoVaultBase.t.sol";

contract RequestRedeemYoVaultIntegrationFuzzTest is YoVaultBase_Test {
    /// @dev When the vault has full liquidity, requestRedeem returns the assets-with-fee amount
    ///      (instant path) and burns shares.
    function testFuzz_RequestRedeem_InstantPath(uint256 assets) external {
        assets = bound(assets, 1, 500_000e6);
        vm.prank(users.alice);
        yoVault.deposit(assets, users.alice);
        uint256 shares = yoVault.balanceOf(users.alice);

        vm.prank(users.alice);
        uint256 ret = yoVault.requestRedeem(shares, users.alice, users.alice);

        assertGt(ret, 0, "instant returns > 0");
        assertEq(yoVault.balanceOf(users.alice), 0, "shares burned");
    }

    /// @dev When the vault is illiquid, the call returns REQUEST_ID (0) and escrows shares to
    ///      the vault. totalPendingAssets grows by exactly `previewRedeem(shares)`.
    function testFuzz_RequestRedeem_QueuedPath(uint256 assets) external {
        assets = bound(assets, 1, 500_000e6);
        vm.prank(users.alice);
        yoVault.deposit(assets, users.alice);

        _moveAssetsFromVault(assets);

        uint256 shares = yoVault.balanceOf(users.alice);
        uint256 expectedAssetsWithFee = yoVault.previewRedeem(shares) + 0; // fee=0 in base
        // previewRedeem subtracts the withdraw-fee component; with fee=0 this equals shares.
        uint256 totalPendingBefore = yoVault.totalPendingAssets();

        vm.prank(users.alice);
        uint256 ret = yoVault.requestRedeem(shares, users.alice, users.alice);

        assertEq(ret, 0, "queued returns REQUEST_ID = 0");
        assertEq(yoVault.balanceOf(users.alice), 0, "shares moved out of alice");
        assertEq(yoVault.balanceOf(address(yoVault)), shares, "shares escrowed");

        // Pending bookkeeping
        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);
        assertEq(pendingShares, shares, "pending shares == redeemed");
        assertGt(pendingAssets, 0, "pending assets > 0");
        assertEq(yoVault.totalPendingAssets(), totalPendingBefore + pendingAssets, "totalPending delta");
        // previewRedeem with fee=0 returns the share amount directly.
        assertEq(pendingAssets, expectedAssetsWithFee);
    }

    /// @dev Revert ordering: ZeroReceiver beats SharesAmountZero beats NotSharesOwner beats
    ///      InsufficientShares. Each fuzz input lands on exactly one revert by construction.
    function testFuzz_RequestRedeem_RevertOrdering(uint256 deposit, uint8 violationKind) external {
        deposit = bound(deposit, 1, 500_000e6);
        violationKind = uint8(bound(uint256(violationKind), 0, 3));

        vm.prank(users.alice);
        yoVault.deposit(deposit, users.alice);
        uint256 shares = yoVault.balanceOf(users.alice);

        if (violationKind == 0) {
            // ZeroReceiver
            vm.prank(users.alice);
            vm.expectRevert(Errors.ZeroReceiver.selector);
            yoVault.requestRedeem(shares, address(0), users.alice);
        } else if (violationKind == 1) {
            // SharesAmountZero (also has ZeroReceiver check first; pass a real receiver)
            vm.prank(users.alice);
            vm.expectRevert(Errors.SharesAmountZero.selector);
            yoVault.requestRedeem(0, users.alice, users.alice);
        } else if (violationKind == 2) {
            // NotSharesOwner — `owner != msg.sender`
            vm.prank(users.alice);
            vm.expectRevert(Errors.NotSharesOwner.selector);
            yoVault.requestRedeem(shares, users.alice, users.bob);
        } else {
            // InsufficientShares — shares > balance
            vm.prank(users.alice);
            vm.expectRevert(Errors.InsufficientShares.selector);
            yoVault.requestRedeem(shares + 1, users.alice, users.alice);
        }
    }
}
