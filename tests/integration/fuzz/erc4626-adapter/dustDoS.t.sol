// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { Integration_Test } from "../../Integration.t.sol";

/// @notice Regression for the audit finding: pre-existing dust at the adapter address must NOT
///         permanently DoS deposits via the absolute-zero post-condition.
contract DustDoS_ERC4626Adapter_Integration_Fuzz_Test is Integration_Test {
    function testFuzz_PreExistingDust_DoesNotBlockDeposit(uint256 dust, uint256 assets) external {
        dust = bound(dust, 1, 1000e6);
        assets = bound(assets, 1, 500_000e6);

        usdc.mint(address(yieldAdapter), dust);

        vm.prank(users.vault);
        yieldAdapter.deposit(IERC4626(address(mockYieldVault)), assets);

        assertEq(usdc.balanceOf(address(yieldAdapter)), dust, "dust untouched");
    }
}
