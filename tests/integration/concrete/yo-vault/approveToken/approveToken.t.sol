// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoApprovalRegistry } from "src/interfaces/IYoApprovalRegistry.sol";
import { IYoVault } from "src/interfaces/IYoVault.sol";
import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract ApproveTokenIntegrationConcreteTest is YoVaultBase_Test {
    address private constant SPENDER = address(0xBEEF);
    uint256 private constant CAP = 1_000_000e6;

    function _setVaultApproval(address token, address spender, uint256 cap) internal {
        vm.prank(users.owner);
        approvalRegistry.setApproval(address(yoVault), token, spender, cap);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    AUTH BRANCH
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_CallerNotAuthorized() external {
        // Eve has no role grant on the authority.
        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        yoVault.approveToken(address(usdc), SPENDER, 1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                              REGISTRY UNSET BRANCH
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertGiven_ApprovalRegistryUnset() external {
        // Wipe the registry pointer set in YoVaultBase.setUp().
        vm.prank(users.owner);
        yoVault.setApprovalRegistry(IYoApprovalRegistry(address(0)));

        vm.prank(users.operator);
        vm.expectRevert(IYoVault.ApprovalRegistryUnset.selector);
        yoVault.approveToken(address(usdc), SPENDER, 1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                              SPENDER ALLOWLIST BRANCH
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SpenderNotAllowlisted() external {
        // No registry entry → cap is zero.
        vm.prank(users.operator);
        vm.expectRevert(abi.encodeWithSelector(IYoVault.SpenderNotAllowed.selector, address(usdc), SPENDER));
        yoVault.approveToken(address(usdc), SPENDER, 1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   AMOUNT BRANCHES
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_AmountExceedsCap() external {
        _setVaultApproval(address(usdc), SPENDER, CAP);

        vm.prank(users.operator);
        vm.expectRevert(abi.encodeWithSelector(IYoVault.AmountExceedsCap.selector, CAP + 1, CAP));
        yoVault.approveToken(address(usdc), SPENDER, CAP + 1);
    }

    function test_WhenAmountEqualsCap_SetsAllowance() external {
        _setVaultApproval(address(usdc), SPENDER, CAP);

        vm.prank(users.operator);
        yoVault.approveToken(address(usdc), SPENDER, CAP);

        assertEq(usdc.allowance(address(yoVault), SPENDER), CAP);
    }

    function test_WhenAmountBelowCap_SetsAllowance() external {
        _setVaultApproval(address(usdc), SPENDER, CAP);

        vm.prank(users.operator);
        yoVault.approveToken(address(usdc), SPENDER, CAP / 2);

        assertEq(usdc.allowance(address(yoVault), SPENDER), CAP / 2);
    }

    function test_WhenAmountZero_GivenPriorAllowance_Clears() external {
        _setVaultApproval(address(usdc), SPENDER, CAP);

        vm.startPrank(users.operator);
        yoVault.approveToken(address(usdc), SPENDER, CAP);
        assertEq(usdc.allowance(address(yoVault), SPENDER), CAP);

        yoVault.approveToken(address(usdc), SPENDER, 0);
        vm.stopPrank();

        assertEq(usdc.allowance(address(yoVault), SPENDER), 0);
    }

    function test_WhenAmountZero_GivenNoPriorAllowance_NoOp() external {
        _setVaultApproval(address(usdc), SPENDER, CAP);

        vm.prank(users.operator);
        yoVault.approveToken(address(usdc), SPENDER, 0);

        assertEq(usdc.allowance(address(yoVault), SPENDER), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  OWNER SHORTCIRCUIT
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Owner bypasses the authority check (always authorized) but is still gated by the
    ///      registry. Verifies the access path and the registry path are independent.
    function test_WhenCallerOwner_GoesThroughRegistry() external {
        _setVaultApproval(address(usdc), SPENDER, CAP);

        vm.prank(users.owner);
        yoVault.approveToken(address(usdc), SPENDER, 100);

        assertEq(usdc.allowance(address(yoVault), SPENDER), 100);
    }
}
