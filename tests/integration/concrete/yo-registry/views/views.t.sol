// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoRegistryBase_Test } from "../YoRegistryBase.t.sol";

contract ViewsIntegrationConcreteTest is YoRegistryBase_Test {
    function test_IsYoVault_GivenRegistered_ReturnsTrue() external {
        address v = _makeMockVault();
        vm.prank(users.owner);
        registry.addYoVault(v);
        assertTrue(registry.isYoVault(v));
    }

    function test_IsYoVault_GivenNeverRegistered_ReturnsFalse() external view {
        assertFalse(registry.isYoVault(address(0xCAFE)));
    }

    function test_IsYoVault_GivenRegisteredThenRemoved_ReturnsFalse() external {
        address v = _makeMockVault();
        vm.prank(users.owner);
        registry.addYoVault(v);
        vm.prank(users.owner);
        registry.removeYoVault(v);
        assertFalse(registry.isYoVault(v));
    }

    function test_IsYoVault_AnyCallerCanRead() external {
        address v = _makeMockVault();
        vm.prank(users.owner);
        registry.addYoVault(v);

        vm.prank(users.eve);
        assertTrue(registry.isYoVault(v));
    }

    function test_ListYoVaults_GivenEmpty_ReturnsEmptyArray() external view {
        address[] memory all = registry.listYoVaults();
        assertEq(all.length, 0);
    }

    function test_ListYoVaults_GivenMultiple_ReturnsAll() external {
        address v1 = _makeMockVault();
        address v2 = _makeMockVault();
        address v3 = _makeMockVault();

        vm.startPrank(users.owner);
        registry.addYoVault(v1);
        registry.addYoVault(v2);
        registry.addYoVault(v3);
        vm.stopPrank();

        address[] memory all = registry.listYoVaults();
        assertEq(all.length, 3);
        // EnumerableSet doesn't guarantee insertion order across versions, so check by isYoVault.
        for (uint256 i; i < all.length; ++i) {
            assertTrue(registry.isYoVault(all[i]));
        }
    }

    function test_ListYoVaults_AfterRemove_ReturnsRemaining() external {
        address v1 = _makeMockVault();
        address v2 = _makeMockVault();

        vm.startPrank(users.owner);
        registry.addYoVault(v1);
        registry.addYoVault(v2);
        registry.removeYoVault(v1);
        vm.stopPrank();

        address[] memory all = registry.listYoVaults();
        assertEq(all.length, 1);
        assertEq(all[0], v2);
    }

    function test_ListAndIsConsistent() external {
        address v1 = _makeMockVault();
        address v2 = _makeMockVault();

        vm.startPrank(users.owner);
        registry.addYoVault(v1);
        registry.addYoVault(v2);
        vm.stopPrank();

        address[] memory all = registry.listYoVaults();
        for (uint256 i; i < all.length; ++i) {
            assertTrue(registry.isYoVault(all[i]));
        }
        assertTrue(registry.isYoVault(v1));
        assertTrue(registry.isYoVault(v2));
        assertFalse(registry.isYoVault(address(0xBEEF)));
    }
}
