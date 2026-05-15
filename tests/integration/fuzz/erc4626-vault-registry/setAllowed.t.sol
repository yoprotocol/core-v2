// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Integration_Test } from "../../Integration.t.sol";

contract SetAllowed_ERC4626VaultRegistry_Integration_Fuzz_Test is Integration_Test {
    function testFuzz_SetAllowed_RoundTrips(address vault, address yieldVault, bool allowed) external {
        vm.assume(vault != address(0) && yieldVault != address(0));

        vm.prank(users.owner);
        yieldVaultRegistry.setAllowed(vault, yieldVault, allowed);

        assertEq(yieldVaultRegistry.isAllowed(vault, yieldVault), allowed, "round trip");
    }

    function testFuzz_SetAllowed_PerPairIsolation(
        address vaultA,
        address vaultB,
        address yieldVault,
        bool flagA,
        bool flagB
    )
        external
    {
        vm.assume(vaultA != address(0) && vaultB != address(0) && vaultA != vaultB);
        vm.assume(yieldVault != address(0));

        vm.startPrank(users.owner);
        yieldVaultRegistry.setAllowed(vaultA, yieldVault, flagA);
        yieldVaultRegistry.setAllowed(vaultB, yieldVault, flagB);
        vm.stopPrank();

        assertEq(yieldVaultRegistry.isAllowed(vaultA, yieldVault), flagA);
        assertEq(yieldVaultRegistry.isAllowed(vaultB, yieldVault), flagB);
    }
}
