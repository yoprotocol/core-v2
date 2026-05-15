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

    /// @dev When (vault, token, spender) is not registered (cap == 0), every amount > 0 reverts
    ///      with SpenderNotAllowed. `amount == 0` is rejected with the same error (cap == 0).
    function testFuzz_ApproveToken_UnallowlistedRejected(address spender, uint256 amount) external {
        vm.assume(spender != address(0));
        amount = bound(amount, 0, type(uint128).max);

        vm.prank(users.operator);
        vm.expectRevert(abi.encodeWithSelector(IYoVault.SpenderNotAllowed.selector, address(usdc), spender));
        yoVault.approveToken(address(usdc), spender, amount);
    }

    /// @dev Wiping the approval registry pointer causes every call to revert with
    ///      ApprovalRegistryUnset, regardless of cap state on a prior registry.
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
