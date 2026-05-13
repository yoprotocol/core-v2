// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { IYoERC4626Adapter } from "src/interfaces/IYoERC4626Adapter.sol";

import { MockERC4626 } from "../../../../mocks/MockERC4626.sol";
import { Integration_Test } from "../../../Integration.t.sol";

contract WithdrawAllERC4626IntegrationConcreteTest is Integration_Test {
    function _seedPosition(uint256 amount) internal {
        vm.prank(users.vault);
        yieldAdapter.deposit(mockYieldVault, amount);
    }

    function test_RevertWhen_YieldVaultNotAllowed() external whenCallerVault {
        MockERC4626 other = new MockERC4626(usdc, "Other Yield", "oYV");
        vm.expectRevert(abi.encodeWithSelector(IYoERC4626Adapter.VaultNotAllowed.selector, other));
        yieldAdapter.withdrawAll(other);
    }

    function test_RevertGiven_NoPosition() external whenCallerVault {
        vm.expectRevert(abi.encodeWithSelector(IYoERC4626Adapter.NoPosition.selector, mockYieldVault));
        yieldAdapter.withdrawAll(mockYieldVault);
    }

    function test_RevertGiven_VaultHasNotApprovedAdapterOnShares() external {
        _seedPosition(defaults.SUPPLY_AMOUNT());

        vm.prank(users.vault);
        mockYieldVault.approve(address(yieldAdapter), 0);

        vm.prank(users.vault);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        yieldAdapter.withdrawAll(mockYieldVault);
    }

    function test_GivenApprovedAndPosition_DrainsToVault() external {
        uint256 supplied = defaults.SUPPLY_AMOUNT();
        _seedPosition(supplied);

        uint256 vaultBalBefore = usdc.balanceOf(users.vault);
        uint256 sharesBefore = mockYieldVault.balanceOf(users.vault);
        assertGt(sharesBefore, 0);

        vm.prank(users.vault);
        uint256 assetsReceived = yieldAdapter.withdrawAll(mockYieldVault);

        assertEq(assetsReceived, supplied, "assets received");
        assertEq(usdc.balanceOf(users.vault), vaultBalBefore + supplied, "vault USDC restored");
        assertEq(mockYieldVault.balanceOf(users.vault), 0, "vault position drained");
        assertZeroBalance(address(usdc), address(yieldAdapter));
    }
}
