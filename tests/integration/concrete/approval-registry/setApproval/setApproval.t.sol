// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IYoApprovalRegistry } from "src/interfaces/IYoApprovalRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

/// @notice Reference BTT implementation. Mirrors `setApproval.tree` 1:1 — every leaf has a test, every
///         intermediate condition has a modifier. Use this as the template for the rest of the suite.
contract SetApproval_Integration_Concrete_Test is Integration_Test {
    address private constant TOKEN_NON_ZERO = address(0x1111);
    address private constant SPENDER_NON_ZERO = address(0x2222);

    /*//////////////////////////////////////////////////////////////////////////
                                  REVERT BRANCHES
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_CallerNotOwner() external {
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.eve));
        approvalRegistry.setApproval(users.vault, TOKEN_NON_ZERO, SPENDER_NON_ZERO, 1);
    }

    function test_RevertWhen_VaultZero() external whenCallerOwner {
        vm.expectRevert(IYoApprovalRegistry.ZeroAddress.selector);
        approvalRegistry.setApproval(address(0), TOKEN_NON_ZERO, SPENDER_NON_ZERO, 1);
    }

    function test_RevertWhen_TokenZero() external whenCallerOwner {
        vm.expectRevert(IYoApprovalRegistry.ZeroAddress.selector);
        approvalRegistry.setApproval(users.vault, address(0), SPENDER_NON_ZERO, 1);
    }

    function test_RevertWhen_SpenderZero() external whenCallerOwner {
        vm.expectRevert(IYoApprovalRegistry.ZeroAddress.selector);
        approvalRegistry.setApproval(users.vault, TOKEN_NON_ZERO, address(0), 1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  HAPPY-PATH BRANCHES
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAmountZero_ClearsEntry()
        external
        whenCallerOwner
        whenVaultNotZero
        whenTokenNotZero
        whenSpenderNotZero
    {
        approvalRegistry.setApproval(users.vault, TOKEN_NON_ZERO, SPENDER_NON_ZERO, 100);
        assertEq(approvalRegistry.maxApproval(users.vault, TOKEN_NON_ZERO, SPENDER_NON_ZERO), 100);

        vm.expectEmit(true, true, true, true, address(approvalRegistry));
        emit IYoApprovalRegistry.ApprovalSet(users.vault, TOKEN_NON_ZERO, SPENDER_NON_ZERO, 0);

        approvalRegistry.setApproval(users.vault, TOKEN_NON_ZERO, SPENDER_NON_ZERO, 0);

        assertEq(approvalRegistry.maxApproval(users.vault, TOKEN_NON_ZERO, SPENDER_NON_ZERO), 0);
    }

    function test_GivenNoPriorEntry_SetsAndEmits()
        external
        whenCallerOwner
        whenVaultNotZero
        whenTokenNotZero
        whenSpenderNotZero
    {
        uint256 cap = defaults.APPROVAL_CAP();
        assertEq(approvalRegistry.maxApproval(users.vault, TOKEN_NON_ZERO, SPENDER_NON_ZERO), 0);

        vm.expectEmit(true, true, true, true, address(approvalRegistry));
        emit IYoApprovalRegistry.ApprovalSet(users.vault, TOKEN_NON_ZERO, SPENDER_NON_ZERO, cap);

        approvalRegistry.setApproval(users.vault, TOKEN_NON_ZERO, SPENDER_NON_ZERO, cap);

        assertEq(approvalRegistry.maxApproval(users.vault, TOKEN_NON_ZERO, SPENDER_NON_ZERO), cap);
    }

    function test_GivenPriorEntry_Overwrites()
        external
        whenCallerOwner
        whenVaultNotZero
        whenTokenNotZero
        whenSpenderNotZero
    {
        approvalRegistry.setApproval(users.vault, TOKEN_NON_ZERO, SPENDER_NON_ZERO, 100);
        approvalRegistry.setApproval(users.vault, TOKEN_NON_ZERO, SPENDER_NON_ZERO, 999);
        assertEq(approvalRegistry.maxApproval(users.vault, TOKEN_NON_ZERO, SPENDER_NON_ZERO), 999);
    }
}
