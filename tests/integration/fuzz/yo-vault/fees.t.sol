// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Errors } from "src/libraries/Errors.sol";

import { YoVaultBase_Test } from "../../concrete/yo-vault/YoVaultBase.t.sol";

contract Fees_YoVault_Integration_Fuzz_Test is YoVaultBase_Test {
    using Math for uint256;

    /// @dev `updateDepositFee` rejects every value at or above MAX_FEE (1e17 = 10%).
    function testFuzz_UpdateDepositFee_RejectsAboveMax(uint256 fee) external {
        fee = bound(fee, 1e17, type(uint256).max);
        vm.prank(users.owner);
        vm.expectRevert(Errors.InvalidFee.selector);
        yoVault.updateDepositFee(fee);
    }

    function testFuzz_UpdateWithdrawFee_RejectsAboveMax(uint256 fee) external {
        fee = bound(fee, 1e17, type(uint256).max);
        vm.prank(users.owner);
        vm.expectRevert(Errors.InvalidFee.selector);
        yoVault.updateWithdrawFee(fee);
    }

    /// @dev With a positive deposit fee + fee recipient, every deposit pays exactly the expected
    ///      fee, mints exactly the net shares, and leaves the vault with exactly the net assets.
    function testFuzz_Deposit_PaysExpectedFee(uint256 assets, uint256 fee) external {
        assets = bound(assets, 1e6, 500_000e6);
        fee = bound(fee, 1, 1e17 - 1); // strictly within (0, MAX_FEE)

        vm.startPrank(users.owner);
        yoVault.updateDepositFee(fee);
        yoVault.updateFeeRecipient(users.bob);
        vm.stopPrank();

        uint256 feeAmount = yoVault.exposed_feeOnTotal(assets, fee);
        uint256 net = assets - feeAmount;

        uint256 recipientBefore = usdc.balanceOf(users.bob);
        vm.prank(users.alice);
        yoVault.deposit(assets, users.alice);

        assertEq(yoVault.balanceOf(users.alice), net, "shares == net");
        assertEq(usdc.balanceOf(address(yoVault)), net, "vault holds net");
        assertEq(usdc.balanceOf(users.bob), recipientBefore + feeAmount, "recipient got fee");
        // Fee is always ≤ the deposit (key invariant — protects users from underflow griefing).
        assertLe(feeAmount, assets);
    }

    /// @dev If `feeRecipient == 0` no fee is transferred even when fee > 0. Tokens stay in vault.
    function testFuzz_Deposit_ZeroRecipient_NoFeePayout(uint256 assets, uint256 fee) external {
        assets = bound(assets, 1e6, 500_000e6);
        fee = bound(fee, 1, 1e17 - 1);

        vm.prank(users.owner);
        yoVault.updateDepositFee(fee);
        // feeRecipient is unset by default (= address(0)).

        vm.prank(users.alice);
        yoVault.deposit(assets, users.alice);

        // Vault keeps the full `assets` because the recipient guard fires.
        assertEq(usdc.balanceOf(address(yoVault)), assets);
    }
}
