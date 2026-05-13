// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Integration_Test } from "../../../Integration.t.sol";

contract IsAllowedYieldRegistryIntegrationConcreteTest is Integration_Test {
    function test_GivenVaultNeverAllowlisted_ReturnsFalse() external view {
        assertFalse(yieldVaultRegistry.isAllowed(users.eve, address(mockYieldVault)));
    }

    function test_GivenAllowlisted_DifferentYieldVault_ReturnsFalse() external view {
        // setUp allowlists `mockYieldVault` for `users.vault`; some other random address must be false.
        address otherYield = address(0xDEAD);
        assertTrue(yieldVaultRegistry.isAllowed(users.vault, address(mockYieldVault)));
        assertFalse(yieldVaultRegistry.isAllowed(users.vault, otherYield));
    }

    function test_GivenAllowlisted_SameYieldVault_ReturnsTrue() external view {
        assertTrue(yieldVaultRegistry.isAllowed(users.vault, address(mockYieldVault)));
    }

    function test_GivenAllowlisted_LaterClearedToFalse_ReturnsFalse() external {
        assertTrue(yieldVaultRegistry.isAllowed(users.vault, address(mockYieldVault)));

        vm.prank(users.owner);
        yieldVaultRegistry.setAllowed(users.vault, address(mockYieldVault), false);

        assertFalse(yieldVaultRegistry.isAllowed(users.vault, address(mockYieldVault)));
    }
}
