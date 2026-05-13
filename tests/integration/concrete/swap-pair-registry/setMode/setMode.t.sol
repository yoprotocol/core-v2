// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IYoSwapPairRegistry } from "src/interfaces/IYoSwapPairRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract SetModePairIntegrationConcreteTest is Integration_Test {
    address private constant TOKEN_IN = address(0x1111);
    address private constant TOKEN_OUT = address(0x2222);

    function test_RevertWhen_CallerNotOwner() external {
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.eve));
        pairRegistry.setMode(users.vault, TOKEN_IN, TOKEN_OUT, IYoSwapPairRegistry.PairMode.ORACLE_CHECKED);
    }

    function test_RevertWhen_VaultZero() external whenCallerOwner {
        vm.expectRevert(IYoSwapPairRegistry.ZeroAddress.selector);
        pairRegistry.setMode(address(0), TOKEN_IN, TOKEN_OUT, IYoSwapPairRegistry.PairMode.ORACLE_CHECKED);
    }

    function test_RevertWhen_TokenInZero() external whenCallerOwner whenVaultNotZero {
        vm.expectRevert(IYoSwapPairRegistry.ZeroAddress.selector);
        pairRegistry.setMode(users.vault, address(0), TOKEN_OUT, IYoSwapPairRegistry.PairMode.ORACLE_CHECKED);
    }

    function test_RevertWhen_TokenOutZero() external whenCallerOwner whenVaultNotZero {
        vm.expectRevert(IYoSwapPairRegistry.ZeroAddress.selector);
        pairRegistry.setMode(users.vault, TOKEN_IN, address(0), IYoSwapPairRegistry.PairMode.ORACLE_CHECKED);
    }

    function test_RevertWhen_SameToken() external whenCallerOwner whenVaultNotZero {
        vm.expectRevert(abi.encodeWithSelector(IYoSwapPairRegistry.SameToken.selector, TOKEN_IN));
        pairRegistry.setMode(users.vault, TOKEN_IN, TOKEN_IN, IYoSwapPairRegistry.PairMode.ORACLE_CHECKED);
    }

    function test_GivenOracleChecked_SetsAndEmits() external whenCallerOwner whenVaultNotZero {
        assertFalse(pairRegistry.isAllowed(users.vault, TOKEN_IN, TOKEN_OUT));

        vm.expectEmit(true, true, true, true, address(pairRegistry));
        emit IYoSwapPairRegistry.PairModeSet(
            users.vault, TOKEN_IN, TOKEN_OUT, IYoSwapPairRegistry.PairMode.ORACLE_CHECKED
        );

        pairRegistry.setMode(users.vault, TOKEN_IN, TOKEN_OUT, IYoSwapPairRegistry.PairMode.ORACLE_CHECKED);

        assertEq(
            uint256(pairRegistry.modeOf(users.vault, TOKEN_IN, TOKEN_OUT)),
            uint256(IYoSwapPairRegistry.PairMode.ORACLE_CHECKED)
        );
        assertTrue(pairRegistry.isAllowed(users.vault, TOKEN_IN, TOKEN_OUT));
    }

    function test_GivenOperatorTrusted_SetsAndEmits() external whenCallerOwner whenVaultNotZero {
        vm.expectEmit(true, true, true, true, address(pairRegistry));
        emit IYoSwapPairRegistry.PairModeSet(
            users.vault, TOKEN_IN, TOKEN_OUT, IYoSwapPairRegistry.PairMode.OPERATOR_TRUSTED
        );

        pairRegistry.setMode(users.vault, TOKEN_IN, TOKEN_OUT, IYoSwapPairRegistry.PairMode.OPERATOR_TRUSTED);

        assertEq(
            uint256(pairRegistry.modeOf(users.vault, TOKEN_IN, TOKEN_OUT)),
            uint256(IYoSwapPairRegistry.PairMode.OPERATOR_TRUSTED)
        );
        assertTrue(pairRegistry.isAllowed(users.vault, TOKEN_IN, TOKEN_OUT));
    }

    function test_GivenDisallowed_ClearsAndEmits() external whenCallerOwner whenVaultNotZero {
        pairRegistry.setMode(users.vault, TOKEN_IN, TOKEN_OUT, IYoSwapPairRegistry.PairMode.ORACLE_CHECKED);
        assertTrue(pairRegistry.isAllowed(users.vault, TOKEN_IN, TOKEN_OUT));

        vm.expectEmit(true, true, true, true, address(pairRegistry));
        emit IYoSwapPairRegistry.PairModeSet(
            users.vault, TOKEN_IN, TOKEN_OUT, IYoSwapPairRegistry.PairMode.DISALLOWED
        );

        pairRegistry.setMode(users.vault, TOKEN_IN, TOKEN_OUT, IYoSwapPairRegistry.PairMode.DISALLOWED);
        assertFalse(pairRegistry.isAllowed(users.vault, TOKEN_IN, TOKEN_OUT));
    }
}
