// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { Integration_Test } from "../../Integration.t.sol";

contract DepositRedeem_ERC4626Adapter_Integration_Fuzz_Test is Integration_Test {
    function testFuzz_Deposit_PullsAndSettles(uint256 assets) external {
        assets = bound(assets, 1, 500_000e6);

        uint256 vaultBefore = usdc.balanceOf(users.vault);
        uint256 sharesBefore = mockYieldVault.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 sharesReceived = yieldAdapter.deposit(IERC4626(address(mockYieldVault)), assets);

        assertEq(usdc.balanceOf(users.vault), vaultBefore - assets, "USDC pulled");
        assertEq(mockYieldVault.balanceOf(users.vault), sharesBefore + sharesReceived, "shares delta");

        // Custody invariants
        assertZeroBalance(address(usdc), address(yieldAdapter));
        assertZeroAllowance(address(usdc), address(yieldAdapter), address(mockYieldVault));
    }

    function testFuzz_RoundTrip_DepositThenWithdrawAll(uint256 assets) external {
        assets = bound(assets, 1, 500_000e6);

        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.startPrank(users.vault);
        yieldAdapter.deposit(IERC4626(address(mockYieldVault)), assets);
        uint256 assetsBack = yieldAdapter.withdrawAll(IERC4626(address(mockYieldVault)));
        vm.stopPrank();

        // Mock 4626 is 1:1, so round-trip is lossless.
        assertEq(assetsBack, assets);
        assertEq(usdc.balanceOf(users.vault), vaultBefore, "USDC restored");
        assertZeroBalance(address(usdc), address(yieldAdapter));
        assertZeroBalance(address(mockYieldVault), address(yieldAdapter));
    }
}
