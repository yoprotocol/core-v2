// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";
import { IYoRegistry } from "src/interfaces/IYoRegistry.sol";
import { Errors } from "src/libraries/Errors.sol";

import { YoRegistryBase_Test } from "../YoRegistryBase.t.sol";

contract AddYoVaultIntegrationConcreteTest is YoRegistryBase_Test {
    function test_RevertWhen_CallerNotAuthorized() external {
        address vault = _makeMockVault();
        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        registry.addYoVault(vault);
    }

    function test_RevertWhen_VaultAddressZero() external {
        vm.prank(users.owner);
        vm.expectRevert(Errors.Registry__VaultAddressZero.selector);
        registry.addYoVault(address(0));
    }

    function test_WhenAuthorized_RegistersAndEmits() external {
        address vault = _makeMockVault();
        vm.expectEmit(true, true, true, true, address(registry));
        emit IYoRegistry.YoVaultAdded(address(usdc), vault);

        vm.prank(users.owner);
        registry.addYoVault(vault);

        assertTrue(registry.isYoVault(vault));
    }

    function test_RevertWhen_VaultAlreadyRegistered() external {
        address vault = _makeMockVault();
        vm.prank(users.owner);
        registry.addYoVault(vault);

        vm.prank(users.owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.Registry__VaultAlreadyExists.selector, vault));
        registry.addYoVault(vault);
    }
}
