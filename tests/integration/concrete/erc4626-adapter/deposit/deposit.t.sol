// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IYoERC4626Adapter } from "src/interfaces/IYoERC4626Adapter.sol";

import { MockERC4626 } from "../../../../mocks/MockERC4626.sol";
import { MockReentrantERC20 } from "../../../../mocks/MockReentrantERC20.sol";
import { Integration_Test } from "../../../Integration.t.sol";

contract DepositERC4626IntegrationConcreteTest is Integration_Test {
    function test_RevertWhen_AssetsZero() external whenCallerVault {
        vm.expectRevert(IYoERC4626Adapter.InvalidAmount.selector);
        yieldAdapter.deposit(mockYieldVault, 0);
    }

    function test_RevertWhen_YieldVaultNotAllowed() external whenCallerVault whenAmountNotZero {
        MockERC4626 other = new MockERC4626(usdc, "Other Yield", "oYV");
        uint256 amount = defaults.SUPPLY_AMOUNT();
        vm.expectRevert(abi.encodeWithSelector(IYoERC4626Adapter.VaultNotAllowed.selector, other));
        yieldAdapter.deposit(other, amount);
    }

    function test_RevertGiven_VaultHasNotApprovedAdapter() external whenAmountNotZero {
        vm.prank(users.vault);
        usdc.approve(address(yieldAdapter), 0);

        uint256 amount = defaults.SUPPLY_AMOUNT();
        vm.prank(users.vault);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        yieldAdapter.deposit(mockYieldVault, amount);
    }

    function test_RevertWhen_Reentered() external whenAmountNotZero {
        MockReentrantERC20 rent = new MockReentrantERC20();
        MockERC4626 reentrantYield = new MockERC4626(rent, "Reentrant Yield", "rYV");
        _allowYieldVault(users.vault, reentrantYield);

        rent.mint(users.vault, 1_000e6);
        vm.prank(users.vault);
        rent.approve(address(yieldAdapter), type(uint256).max);

        bytes memory payload = abi.encodeCall(IYoERC4626Adapter.deposit, (reentrantYield, 1));
        rent.arm(address(yieldAdapter), payload);

        vm.prank(users.vault);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        yieldAdapter.deposit(reentrantYield, 100e6);
    }

    function test_GivenApproved_PullsAndDeposits() external whenCallerVault whenAmountNotZero {
        uint256 amount = defaults.SUPPLY_AMOUNT();
        uint256 vaultBalBefore = usdc.balanceOf(users.vault);
        uint256 sharesBefore = mockYieldVault.balanceOf(users.vault);

        uint256 sharesReceived = yieldAdapter.deposit(mockYieldVault, amount);

        assertGt(sharesReceived, 0, "sharesReceived");
        assertEq(usdc.balanceOf(users.vault), vaultBalBefore - amount, "vault USDC out");
        assertEq(
            mockYieldVault.balanceOf(users.vault),
            sharesBefore + sharesReceived,
            "vault share balance"
        );

        assertZeroBalance(address(usdc), address(yieldAdapter));
        assertZeroAllowance(address(usdc), address(yieldAdapter), address(mockYieldVault));
    }
}
