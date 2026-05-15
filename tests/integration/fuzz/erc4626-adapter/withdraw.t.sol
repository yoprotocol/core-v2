// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { Integration_Test } from "../../Integration.t.sol";

contract Withdraw_ERC4626Adapter_Integration_Fuzz_Test is Integration_Test {
    /// @dev Assets-based withdraw delivers exactly `assets` USDC and burns the corresponding shares.
    function testFuzz_Withdraw_DeliversExactAssets(uint256 deposit, uint256 withdrawAssets) external {
        deposit = bound(deposit, 100, 500_000e6);
        withdrawAssets = bound(withdrawAssets, 1, deposit);

        vm.startPrank(users.vault);
        yieldAdapter.deposit(IERC4626(address(mockYieldVault)), deposit);
        uint256 sharesBefore = mockYieldVault.balanceOf(users.vault);
        uint256 vaultUsdcBefore = usdc.balanceOf(users.vault);

        uint256 sharesBurned = yieldAdapter.withdraw(IERC4626(address(mockYieldVault)), withdrawAssets);
        vm.stopPrank();

        // 1:1 mock: shares burned == assets withdrawn.
        assertEq(sharesBurned, withdrawAssets, "1:1 share burn");
        assertEq(
            mockYieldVault.balanceOf(users.vault),
            sharesBefore - sharesBurned,
            "share balance delta"
        );
        assertEq(usdc.balanceOf(users.vault), vaultUsdcBefore + withdrawAssets, "USDC delivered");
        assertZeroBalance(address(usdc), address(yieldAdapter));
    }
}
