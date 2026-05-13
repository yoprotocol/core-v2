// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Integration_Test } from "../../../Integration.t.sol";

contract IsAllowed_Pair_Integration_Concrete_Test is Integration_Test {
    function test_GivenPairNeverAllowlisted_ReturnsFalse() external view {
        assertFalse(pairRegistry.isAllowed(users.eve, address(usdc), address(usdt)));
    }

    function test_GivenAllowlisted_ReverseDirection_ReturnsFalse() external view {
        // Integration_Test.setUp() allowlists USDC -> USDT for `users.vault`. The reverse direction
        // (USDT -> USDC) must remain blocked unless explicitly added.
        assertTrue(pairRegistry.isAllowed(users.vault, address(usdc), address(usdt)));
        assertFalse(pairRegistry.isAllowed(users.vault, address(usdt), address(usdc)));
    }

    function test_GivenAllowlisted_ConfiguredDirection_ReturnsTrue() external view {
        assertTrue(pairRegistry.isAllowed(users.vault, address(usdc), address(usdt)));
    }
}
