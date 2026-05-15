// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoApprovalRegistry } from "src/interfaces/IYoApprovalRegistry.sol";
import { IYoVault } from "src/interfaces/IYoVault.sol";

import { YoVaultBase_Test } from "../../concrete/yo-vault/YoVaultBase.t.sol";

contract ApproveToken_YoVault_Integration_Fuzz_Test is YoVaultBase_Test {
    /// @dev For any cap registered and any `amount <= cap`, the ERC-20 allowance the vault sets
    ///      after `approveToken(amount)` equals exactly `amount`. Above cap → revert.
    function testFuzz_ApproveToken_RespectsCap(uint256 cap, uint256 amount) external {
        // 0 cap == "not allowlisted" by registry convention; require strictly positive.
        cap = bound(cap, 1, type(uint128).max);
        amount = bound(amount, 0, cap * 2);

        address spender = address(0xBEEF);
        vm.prank(users.owner);
        approvalRegistry.setApproval(address(yoVault), address(usdc), spender, cap);

        if (amount > cap) {
            vm.prank(users.operator);
            vm.expectRevert(abi.encodeWithSelector(IYoVault.AmountExceedsCap.selector, amount, cap));
            yoVault.approveToken(address(usdc), spender, amount);
        } else {
            vm.prank(users.operator);
            yoVault.approveToken(address(usdc), spender, amount);
            assertEq(usdc.allowance(address(yoVault), spender), amount);
        }
    }

    /// @dev When (vault, token, spender) is not registered (cap == 0), every positive `amount`
    ///      reverts with SpenderNotAllowed. `amount == 0` is permitted so an allowance can be
    ///      revoked even after the admin sets the cap to zero.
    function testFuzz_ApproveToken_UnallowlistedRejectsPositiveButAllowsRevoke(
        address spender,
        uint256 amount
    )
        external
    {
        vm.assume(spender != address(0));
        amount = bound(amount, 1, type(uint128).max);

        // Positive amount: reverts with SpenderNotAllowed.
        vm.prank(users.operator);
        vm.expectRevert(abi.encodeWithSelector(IYoVault.SpenderNotAllowed.selector, address(usdc), spender));
        yoVault.approveToken(address(usdc), spender, amount);

        // `amount == 0` (revoke path): permitted regardless of cap. No assertion side-effect since
        // there was no prior allowance, but the call must not revert.
        vm.prank(users.operator);
        yoVault.approveToken(address(usdc), spender, 0);
    }

    /// @dev Revocation path: with a live allowance in place, an admin setting cap to 0 (intended
    ///      "disable spender") must not prevent the operator from clearing the still-live ERC-20
    ///      allowance via approveToken(token, spender, 0).
    function testFuzz_ApproveToken_RevokeAfterCapClearedToZero(uint256 cap, uint256 amount) external {
        cap = bound(cap, 1, type(uint128).max);
        amount = bound(amount, 1, cap);
        address spender = address(0xBEEF);

        // Step 1: register cap and approve a live allowance.
        vm.prank(users.owner);
        approvalRegistry.setApproval(address(yoVault), address(usdc), spender, cap);
        vm.prank(users.operator);
        yoVault.approveToken(address(usdc), spender, amount);
        assertEq(usdc.allowance(address(yoVault), spender), amount, "allowance live");

        // Step 2: admin "disables" spender by setting cap to 0.
        vm.prank(users.owner);
        approvalRegistry.setApproval(address(yoVault), address(usdc), spender, 0);

        // Step 3: operator must still be able to clear the live allowance.
        vm.prank(users.operator);
        yoVault.approveToken(address(usdc), spender, 0);
        assertEq(usdc.allowance(address(yoVault), spender), 0, "allowance cleared");
    }

    /// @dev Wiping the approval registry pointer causes every call to revert with
    ///      ApprovalRegistryUnset — including `amount == 0` (no registry → no surface, period).
    function testFuzz_ApproveToken_RevertsWhenRegistryUnset(address spender, uint256 amount) external {
        vm.assume(spender != address(0));
        amount = bound(amount, 0, type(uint128).max);

        vm.prank(users.owner);
        yoVault.setApprovalRegistry(IYoApprovalRegistry(address(0)));

        vm.prank(users.operator);
        vm.expectRevert(IYoVault.ApprovalRegistryUnset.selector);
        yoVault.approveToken(address(usdc), spender, amount);
    }
}
