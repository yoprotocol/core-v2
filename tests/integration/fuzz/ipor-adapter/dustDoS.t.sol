// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Integration_Test } from "../../Integration.t.sol";

/// @notice Regression for the dust-DoS class: pre-existing token / share dust at the adapter must
///         not block deposit or claim. Mirrors the analogous test for `YoERC4626Adapter`. The IPOR
///         adapter has the same shape (no absolute-zero post-condition), so this is the smoke
///         test that proves the cleanup didn't regress.
contract DustDoS_IPORAdapter_Integration_Fuzz_Test is Integration_Test {
    function testFuzz_PreExistingDust_DoesNotBlockDeposit(uint256 dust, uint256 assets) external {
        dust = bound(dust, 1, 1000e6);
        assets = bound(assets, 1, 500_000e6);

        usdc.mint(address(iporAdapter), dust);

        vm.prank(users.vault);
        iporAdapter.deposit(mockPlasmaVault, assets);

        assertEq(usdc.balanceOf(address(iporAdapter)), dust, "USDC dust untouched");
    }

    function testFuzz_PreExistingShareDust_DoesNotBlockClaim(uint256 dust, uint256 assets) external {
        dust = bound(dust, 1, 1000e6);
        assets = bound(assets, 1, 500_000e6);

        // Adversary plants PlasmaVault share dust at the adapter directly. Real flow: someone
        // mints to the adapter, or shares get stuck mid-prior-call.
        usdc.mint(address(this), dust);
        usdc.approve(address(mockPlasmaVault), dust);
        mockPlasmaVault.deposit(dust, address(iporAdapter));
        uint256 dustShares = mockPlasmaVault.balanceOf(address(iporAdapter));

        // Standard vault flow.
        vm.prank(users.vault);
        uint256 shares = iporAdapter.deposit(mockPlasmaVault, assets);

        vm.prank(users.vault);
        mockIPORWithdrawManager.requestShares(shares);

        vm.warp(block.timestamp + 1);
        mockIPORWithdrawManager.releaseFunds(block.timestamp, shares);

        vm.prank(users.vault);
        iporAdapter.claim(mockPlasmaVault, shares);

        // Pre-existing share dust at the adapter is untouched by the claim — only the vault's
        // shares (via allowance) are burned.
        assertEq(mockPlasmaVault.balanceOf(address(iporAdapter)), dustShares, "share dust untouched");
    }
}
