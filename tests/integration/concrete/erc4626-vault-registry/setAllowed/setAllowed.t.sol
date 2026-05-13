// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IYoERC4626VaultRegistry } from "src/interfaces/IYoERC4626VaultRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract SetAllowedYieldRegistryIntegrationConcreteTest is Integration_Test {
    address private constant YIELD = address(0x1111);

    function test_RevertWhen_CallerNotOwner() external {
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.eve));
        yieldVaultRegistry.setAllowed(users.vault, YIELD, true);
    }

    function test_RevertWhen_VaultZero() external whenCallerOwner {
        vm.expectRevert(IYoERC4626VaultRegistry.ZeroAddress.selector);
        yieldVaultRegistry.setAllowed(address(0), YIELD, true);
    }

    function test_RevertWhen_YieldVaultZero() external whenCallerOwner whenVaultNotZero {
        vm.expectRevert(IYoERC4626VaultRegistry.ZeroAddress.selector);
        yieldVaultRegistry.setAllowed(users.vault, address(0), true);
    }

    function test_GivenAllowedTrue_GivenNoPriorEntry_SetsAndEmits() external whenCallerOwner whenVaultNotZero {
        assertFalse(yieldVaultRegistry.isAllowed(users.vault, YIELD));

        vm.expectEmit(true, true, true, true, address(yieldVaultRegistry));
        emit IYoERC4626VaultRegistry.VaultAllowed(users.vault, YIELD, true);

        yieldVaultRegistry.setAllowed(users.vault, YIELD, true);
        assertTrue(yieldVaultRegistry.isAllowed(users.vault, YIELD));
    }

    function test_GivenAllowedTrue_GivenPriorEntryTrue_Idempotent() external whenCallerOwner whenVaultNotZero {
        yieldVaultRegistry.setAllowed(users.vault, YIELD, true);
        yieldVaultRegistry.setAllowed(users.vault, YIELD, true);
        assertTrue(yieldVaultRegistry.isAllowed(users.vault, YIELD));
    }

    function test_GivenAllowedFalse_GivenPriorEntryTrue_ClearsAndEmits() external whenCallerOwner whenVaultNotZero {
        yieldVaultRegistry.setAllowed(users.vault, YIELD, true);
        assertTrue(yieldVaultRegistry.isAllowed(users.vault, YIELD));

        vm.expectEmit(true, true, true, true, address(yieldVaultRegistry));
        emit IYoERC4626VaultRegistry.VaultAllowed(users.vault, YIELD, false);

        yieldVaultRegistry.setAllowed(users.vault, YIELD, false);
        assertFalse(yieldVaultRegistry.isAllowed(users.vault, YIELD));
    }

    function test_GivenAllowedFalse_GivenNoPriorEntry_Emits() external whenCallerOwner whenVaultNotZero {
        vm.expectEmit(true, true, true, true, address(yieldVaultRegistry));
        emit IYoERC4626VaultRegistry.VaultAllowed(users.vault, YIELD, false);

        yieldVaultRegistry.setAllowed(users.vault, YIELD, false);
        assertFalse(yieldVaultRegistry.isAllowed(users.vault, YIELD));
    }
}
