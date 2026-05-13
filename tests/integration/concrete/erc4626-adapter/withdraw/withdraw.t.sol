// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { IYoERC4626Adapter } from "src/interfaces/IYoERC4626Adapter.sol";

import { MockERC4626 } from "../../../../mocks/MockERC4626.sol";
import { Integration_Test } from "../../../Integration.t.sol";

contract WithdrawERC4626IntegrationConcreteTest is Integration_Test {
    function _seedPosition(uint256 amount) internal returns (uint256 sharesMinted) {
        vm.prank(users.vault);
        sharesMinted = yieldAdapter.deposit(mockYieldVault, amount);
    }

    function test_RevertWhen_AssetsZero() external whenCallerVault {
        vm.expectRevert(IYoERC4626Adapter.InvalidAmount.selector);
        yieldAdapter.withdraw(mockYieldVault, 0);
    }

    function test_RevertWhen_YieldVaultNotAllowed() external whenCallerVault whenAmountNotZero {
        MockERC4626 other = new MockERC4626(usdc, "Other Yield", "oYV");
        vm.expectRevert(abi.encodeWithSelector(IYoERC4626Adapter.VaultNotAllowed.selector, other));
        yieldAdapter.withdraw(other, 1e6);
    }

    function test_RevertGiven_VaultHasNotApprovedAdapterOnShares() external whenAmountNotZero {
        _seedPosition(defaults.SUPPLY_AMOUNT());

        vm.prank(users.vault);
        mockYieldVault.approve(address(yieldAdapter), 0);

        uint256 amount = defaults.SUPPLY_AMOUNT() / 2;
        vm.prank(users.vault);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        yieldAdapter.withdraw(mockYieldVault, amount);
    }

    function test_RevertGiven_AssetsExceedsPosition() external whenAmountNotZero {
        _seedPosition(defaults.SUPPLY_AMOUNT());

        uint256 tooMuch = defaults.SUPPLY_AMOUNT() * 2;
        vm.prank(users.vault);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxWithdraw.selector);
        yieldAdapter.withdraw(mockYieldVault, tooMuch);
    }

    function test_GivenAssetsWithinPosition_TransfersAndBurns() external whenAmountNotZero {
        uint256 supplied = defaults.SUPPLY_AMOUNT();
        uint256 sharesMinted = _seedPosition(supplied);

        uint256 toWithdraw = supplied / 2;
        uint256 vaultBalBefore = usdc.balanceOf(users.vault);
        uint256 sharesBefore = mockYieldVault.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 sharesBurned = yieldAdapter.withdraw(mockYieldVault, toWithdraw);

        assertGt(sharesBurned, 0, "sharesBurned");
        assertLe(sharesBurned, sharesMinted, "sharesBurned <= sharesMinted");
        assertEq(usdc.balanceOf(users.vault), vaultBalBefore + toWithdraw, "vault USDC delta");
        assertEq(
            mockYieldVault.balanceOf(users.vault),
            sharesBefore - sharesBurned,
            "vault share delta"
        );

        assertZeroBalance(address(usdc), address(yieldAdapter));
        assertEq(mockYieldVault.balanceOf(address(yieldAdapter)), 0, "adapter share balance");
    }
}
