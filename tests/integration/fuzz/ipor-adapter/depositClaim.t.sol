// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Integration_Test } from "../../Integration.t.sol";

contract DepositClaim_IPORAdapter_Integration_Fuzz_Test is Integration_Test {
    function testFuzz_Deposit_PullsAndSettles(uint256 assets) external {
        assets = bound(assets, 1, 500_000e6);

        uint256 vaultBefore = usdc.balanceOf(users.vault);
        uint256 sharesBefore = mockPlasmaVault.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 sharesReceived = iporAdapter.deposit(mockPlasmaVault, assets);

        assertEq(usdc.balanceOf(users.vault), vaultBefore - assets, "USDC pulled");
        assertEq(mockPlasmaVault.balanceOf(users.vault), sharesBefore + sharesReceived, "shares delta");

        // Custody invariants.
        assertZeroBalance(address(usdc), address(iporAdapter));
        assertZeroAllowance(address(usdc), address(iporAdapter), address(mockPlasmaVault));
    }

    /// @dev Full async round-trip: deposit → request → release → claim. Mock PlasmaVault is 1:1
    ///      so this should be lossless.
    function testFuzz_RoundTrip_DepositRequestReleaseClaim(uint256 assets) external {
        assets = bound(assets, 1, 500_000e6);

        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 shares = iporAdapter.deposit(mockPlasmaVault, assets);

        // Vault places request directly on the WithdrawManager (the `manage()`-path real YO vaults
        // take).
        vm.prank(users.vault);
        mockIPORWithdrawManager.requestShares(shares);

        // Move past request timestamp and have the keeper release.
        vm.warp(block.timestamp + 1);
        mockIPORWithdrawManager.releaseFunds(block.timestamp, shares);

        vm.prank(users.vault);
        uint256 assetsBack = iporAdapter.claim(mockPlasmaVault, shares);

        assertEq(assetsBack, assets, "round-trip is lossless on 1:1 mock");
        assertEq(usdc.balanceOf(users.vault), vaultBefore, "USDC restored");
        assertZeroBalance(address(usdc), address(iporAdapter));
        assertZeroBalance(address(mockPlasmaVault), address(iporAdapter));
    }

    /// @dev Partial claim: request all, claim half in window, leave the rest for a later (separate)
    ///      window. Validates that `redeemFromRequest` correctly decrements both the per-account
    ///      slot and the global release pool on the partial path.
    function testFuzz_PartialClaim_DecrementsSlotAndPool(uint256 assets) external {
        assets = bound(assets, 2, 500_000e6);

        vm.prank(users.vault);
        uint256 shares = iporAdapter.deposit(mockPlasmaVault, assets);

        vm.prank(users.vault);
        mockIPORWithdrawManager.requestShares(shares);

        vm.warp(block.timestamp + 1);
        mockIPORWithdrawManager.releaseFunds(block.timestamp, shares);

        uint256 half = shares / 2;
        vm.assume(half > 0);

        vm.prank(users.vault);
        iporAdapter.claim(mockPlasmaVault, half);

        // The request slot and global pool both decreased by `half`.
        assertEq(mockIPORWithdrawManager.requestInfo(users.vault).shares, shares - half, "slot decremented");
        assertEq(mockIPORWithdrawManager.sharesToRelease(), shares - half, "pool decremented");
    }
}
