// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IYoSwapPairRegistry } from "src/interfaces/IYoSwapPairRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract SetAllowed_Pair_Integration_Concrete_Test is Integration_Test {
    address private constant TOKEN_IN = address(0x1111);
    address private constant TOKEN_OUT = address(0x2222);

    function test_RevertWhen_CallerNotOwner() external {
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.eve));
        pairRegistry.setAllowed(users.vault, TOKEN_IN, TOKEN_OUT, true);
    }

    function test_RevertWhen_VaultZero() external whenCallerOwner {
        vm.expectRevert(IYoSwapPairRegistry.ZeroAddress.selector);
        pairRegistry.setAllowed(address(0), TOKEN_IN, TOKEN_OUT, true);
    }

    function test_RevertWhen_TokenInZero() external whenCallerOwner whenVaultNotZero {
        vm.expectRevert(IYoSwapPairRegistry.ZeroAddress.selector);
        pairRegistry.setAllowed(users.vault, address(0), TOKEN_OUT, true);
    }

    function test_RevertWhen_TokenOutZero() external whenCallerOwner whenVaultNotZero {
        vm.expectRevert(IYoSwapPairRegistry.ZeroAddress.selector);
        pairRegistry.setAllowed(users.vault, TOKEN_IN, address(0), true);
    }

    function test_RevertWhen_SameToken() external whenCallerOwner whenVaultNotZero {
        vm.expectRevert(abi.encodeWithSelector(IYoSwapPairRegistry.SameToken.selector, TOKEN_IN));
        pairRegistry.setAllowed(users.vault, TOKEN_IN, TOKEN_IN, true);
    }

    function test_GivenAllowedTrue_SetsAndEmits() external whenCallerOwner whenVaultNotZero {
        assertFalse(pairRegistry.isAllowed(users.vault, TOKEN_IN, TOKEN_OUT));

        vm.expectEmit(true, true, true, true, address(pairRegistry));
        emit IYoSwapPairRegistry.PairAllowed(users.vault, TOKEN_IN, TOKEN_OUT, true);

        pairRegistry.setAllowed(users.vault, TOKEN_IN, TOKEN_OUT, true);
        assertTrue(pairRegistry.isAllowed(users.vault, TOKEN_IN, TOKEN_OUT));
    }

    function test_GivenAllowedFalse_ClearsAndEmits() external whenCallerOwner whenVaultNotZero {
        pairRegistry.setAllowed(users.vault, TOKEN_IN, TOKEN_OUT, true);
        assertTrue(pairRegistry.isAllowed(users.vault, TOKEN_IN, TOKEN_OUT));

        vm.expectEmit(true, true, true, true, address(pairRegistry));
        emit IYoSwapPairRegistry.PairAllowed(users.vault, TOKEN_IN, TOKEN_OUT, false);

        pairRegistry.setAllowed(users.vault, TOKEN_IN, TOKEN_OUT, false);
        assertFalse(pairRegistry.isAllowed(users.vault, TOKEN_IN, TOKEN_OUT));
    }
}
