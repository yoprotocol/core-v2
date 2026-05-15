// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { Id } from "src/interfaces/IMorpho.sol";
import { IYoMorphoMarketRegistry } from "src/interfaces/IYoMorphoMarketRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract SetAllowed_MarketRegistry_Integration_Concrete_Test is Integration_Test {
    function test_RevertWhen_CallerNotOwner() external {
        Id m = defaults.MARKET_A();
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.eve));
        marketRegistry.setAllowed(users.vault, m, true);
    }

    function test_RevertWhen_VaultZero() external whenCallerOwner {
        Id m = defaults.MARKET_A();
        vm.expectRevert(IYoMorphoMarketRegistry.ZeroAddress.selector);
        marketRegistry.setAllowed(address(0), m, true);
    }

    function test_GivenAllowedFalse_GivenPriorEntryTrue_ClearsAndEmits() external whenCallerOwner whenVaultNotZero {
        Id m = defaults.MARKET_B();
        marketRegistry.setAllowed(users.vault, m, true);
        assertTrue(marketRegistry.isAllowed(users.vault, m));

        vm.expectEmit(true, true, true, true, address(marketRegistry));
        emit IYoMorphoMarketRegistry.MarketAllowed(users.vault, m, false);

        marketRegistry.setAllowed(users.vault, m, false);
        assertFalse(marketRegistry.isAllowed(users.vault, m));
    }

    function test_GivenAllowedFalse_GivenNoPriorEntry_LeavesFalseAndEmits() external whenCallerOwner whenVaultNotZero {
        Id m = defaults.MARKET_NULL();
        assertFalse(marketRegistry.isAllowed(users.vault, m));

        vm.expectEmit(true, true, true, true, address(marketRegistry));
        emit IYoMorphoMarketRegistry.MarketAllowed(users.vault, m, false);

        marketRegistry.setAllowed(users.vault, m, false);
        assertFalse(marketRegistry.isAllowed(users.vault, m));
    }

    function test_GivenAllowedTrue_GivenPriorEntryFalse_SetsAndEmits() external whenCallerOwner whenVaultNotZero {
        Id m = defaults.MARKET_B();
        assertFalse(marketRegistry.isAllowed(users.vault, m));

        vm.expectEmit(true, true, true, true, address(marketRegistry));
        emit IYoMorphoMarketRegistry.MarketAllowed(users.vault, m, true);

        marketRegistry.setAllowed(users.vault, m, true);
        assertTrue(marketRegistry.isAllowed(users.vault, m));
    }

    function test_GivenAllowedTrue_GivenPriorEntryTrue_Idempotent() external whenCallerOwner whenVaultNotZero {
        Id m = defaults.MARKET_B();
        marketRegistry.setAllowed(users.vault, m, true);
        marketRegistry.setAllowed(users.vault, m, true);
        assertTrue(marketRegistry.isAllowed(users.vault, m));
    }
}
