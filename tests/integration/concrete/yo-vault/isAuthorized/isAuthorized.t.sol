// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract IsAuthorizedIntegrationConcreteTest is YoVaultBase_Test {
    function test_GivenOwner_ReturnsTrueForAnySelector() external view {
        assertTrue(yoVault.isAuthorized(users.owner, bytes4(0xdeadbeef)));
        assertTrue(yoVault.isAuthorized(users.owner, MANAGE_SINGLE_SELECTOR));
    }

    function test_GivenCallerGrantedByAuthority_ReturnsTrue() external view {
        // Set in `YoVaultBase.setUp()`.
        assertTrue(yoVault.isAuthorized(users.operator, MANAGE_SINGLE_SELECTOR));
    }

    function test_GivenCallerNotGranted_ReturnsFalse() external view {
        assertFalse(yoVault.isAuthorized(users.eve, MANAGE_SINGLE_SELECTOR));
    }
}
