// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";
import { IYoRegistry } from "src/interfaces/IYoRegistry.sol";
import { Errors } from "src/libraries/Errors.sol";

import { YoRegistryBase_Test } from "../YoRegistryBase.t.sol";

contract RemoveYoVaultIntegrationConcreteTest is YoRegistryBase_Test {
    function test_RevertWhen_CallerNotAuthorized() external {
        address vault = _makeMockVault();
        vm.prank(users.owner);
        registry.addYoVault(vault);

        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        registry.removeYoVault(vault);
    }

    function test_RevertWhen_VaultAddressZero() external {
        vm.prank(users.owner);
        vm.expectRevert(Errors.Registry__VaultAddressZero.selector);
        registry.removeYoVault(address(0));
    }

    function test_WhenAuthorized_UnregistersAndEmits() external {
        address vault = _makeMockVault();
        vm.prank(users.owner);
        registry.addYoVault(vault);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IYoRegistry.YoVaultRemoved(address(usdc), vault);

        vm.prank(users.owner);
        registry.removeYoVault(vault);

        assertFalse(registry.isYoVault(vault));
    }

    function test_RevertWhen_VaultNotRegistered() external {
        address vault = _makeMockVault();
        vm.prank(users.owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.Registry__VaultNotExists.selector, vault));
        registry.removeYoVault(vault);
    }
}
