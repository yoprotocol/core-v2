// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { IIPORPlasmaVault } from "src/interfaces/external/IIPORPlasmaVault.sol";
import { IYoIPORAdapter } from "src/interfaces/IYoIPORAdapter.sol";

import { MockIIPORPlasmaVault } from "../../../../mocks/MockIIPORPlasmaVault.sol";
import { MockIIPORWithdrawManager } from "../../../../mocks/MockIIPORWithdrawManager.sol";
import { MockReentrantERC20 } from "../../../../mocks/MockReentrantERC20.sol";
import { Integration_Test } from "../../../Integration.t.sol";

contract DepositIPORIntegrationConcreteTest is Integration_Test {
    function test_RevertWhen_AssetsZero() external whenCallerVault {
        vm.expectRevert(IYoIPORAdapter.InvalidAmount.selector);
        iporAdapter.deposit(mockPlasmaVault, 0);
    }

    function test_RevertWhen_PlasmaVaultNotAllowed() external whenCallerVault whenAmountNotZero {
        MockIIPORWithdrawManager otherManager = new MockIIPORWithdrawManager(defaults.IPOR_WITHDRAW_WINDOW());
        MockIIPORPlasmaVault other = new MockIIPORPlasmaVault(usdc, "Other Plasma", "oPV", otherManager);

        uint256 amount = defaults.SUPPLY_AMOUNT();
        vm.expectRevert(abi.encodeWithSelector(IYoIPORAdapter.VaultNotAllowed.selector, other));
        iporAdapter.deposit(other, amount);
    }

    function test_RevertGiven_VaultHasNotApprovedAdapter() external whenAmountNotZero {
        vm.prank(users.vault);
        usdc.approve(address(iporAdapter), 0);

        uint256 amount = defaults.SUPPLY_AMOUNT();
        vm.prank(users.vault);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        iporAdapter.deposit(mockPlasmaVault, amount);
    }

    function test_RevertWhen_Reentered() external whenAmountNotZero {
        MockReentrantERC20 rent = new MockReentrantERC20();
        MockIIPORWithdrawManager rentManager = new MockIIPORWithdrawManager(defaults.IPOR_WITHDRAW_WINDOW());
        MockIIPORPlasmaVault reentrantPlasma = new MockIIPORPlasmaVault(rent, "Reentrant Plasma", "rPV", rentManager);
        _allowYieldVault(users.vault, reentrantPlasma);

        rent.mint(users.vault, 1000e6);
        vm.prank(users.vault);
        rent.approve(address(iporAdapter), type(uint256).max);

        bytes memory payload = abi.encodeCall(IYoIPORAdapter.deposit, (IIPORPlasmaVault(address(reentrantPlasma)), 1));
        rent.arm(address(iporAdapter), payload);

        vm.prank(users.vault);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        iporAdapter.deposit(reentrantPlasma, 100e6);
    }

    function test_GivenApproved_PullsAndDeposits() external whenCallerVault whenAmountNotZero {
        uint256 amount = defaults.SUPPLY_AMOUNT();
        uint256 vaultBalBefore = usdc.balanceOf(users.vault);
        uint256 sharesBefore = mockPlasmaVault.balanceOf(users.vault);

        uint256 sharesReceived = iporAdapter.deposit(mockPlasmaVault, amount);

        assertGt(sharesReceived, 0, "sharesReceived");
        assertEq(usdc.balanceOf(users.vault), vaultBalBefore - amount, "vault USDC out");
        assertEq(mockPlasmaVault.balanceOf(users.vault), sharesBefore + sharesReceived, "vault share balance");

        assertZeroBalance(address(usdc), address(iporAdapter));
        assertZeroAllowance(address(usdc), address(iporAdapter), address(mockPlasmaVault));
    }

    function test_EmitsAdapterAction() external whenCallerVault whenAmountNotZero {
        uint256 amount = defaults.SUPPLY_AMOUNT();
        vm.expectEmit(true, true, true, true, address(iporAdapter));
        emit YoAdapterBase.AdapterAction(
            users.vault,
            address(mockPlasmaVault),
            address(usdc),
            YoAdapterBase.AdapterDirection.Deposit,
            amount
        );
        iporAdapter.deposit(mockPlasmaVault, amount);
    }
}
