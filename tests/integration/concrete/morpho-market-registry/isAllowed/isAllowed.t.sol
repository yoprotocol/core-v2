// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "src/interfaces/IMorpho.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract IsAllowed_Market_Integration_Concrete_Test is Integration_Test {
    function test_GivenVaultNeverAllowlisted_ReturnsFalse() external view {
        // `users.eve` is never touched by the registry.
        assertFalse(marketRegistry.isAllowed(users.eve, defaults.MARKET_A()));
    }

    function test_GivenAllowlisted_DifferentMarket_ReturnsFalse() external view {
        // `users.vault` is allowlisted for MARKET_A in Integration_Test.setUp(); MARKET_B is not.
        assertTrue(marketRegistry.isAllowed(users.vault, defaults.MARKET_A()));
        assertFalse(marketRegistry.isAllowed(users.vault, defaults.MARKET_B()));
    }

    function test_GivenAllowlisted_SameMarket_ReturnsTrue() external view {
        assertTrue(marketRegistry.isAllowed(users.vault, defaults.MARKET_A()));
    }

    function test_GivenAllowlisted_LaterClearedToFalse_ReturnsFalse() external {
        Id m = defaults.MARKET_A();
        assertTrue(marketRegistry.isAllowed(users.vault, m));

        vm.prank(users.owner);
        marketRegistry.setAllowed(users.vault, m, false);

        assertFalse(marketRegistry.isAllowed(users.vault, m));
    }
}
