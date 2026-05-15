// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoGateway } from "src/interfaces/IYoGateway.sol";
import { Errors } from "src/libraries/Errors.sol";

import { YoGatewayBase_Test } from "../YoGatewayBase.t.sol";

contract DepositIntegrationConcreteTest is YoGatewayBase_Test {
    uint256 internal constant ASSETS = 1000e6;
    uint256 internal constant MIN_SHARES_OUT = 1; // mock vault is 1:1 on empty deposit
    uint32 internal constant PARTNER_ID = 42;

    function test_WhenValid_TransfersAndMints() external {
        uint256 callerBefore = usdc.balanceOf(users.alice);
        uint256 sharesBefore = mockVault.balanceOf(users.alice);

        vm.prank(users.alice);
        uint256 sharesOut = gateway.deposit(address(mockVault), ASSETS, MIN_SHARES_OUT, users.alice, PARTNER_ID);

        assertEq(usdc.balanceOf(users.alice), callerBefore - ASSETS);
        assertEq(mockVault.balanceOf(users.alice), sharesBefore + sharesOut);
        assertGt(sharesOut, 0);
    }

    function test_WhenDifferentReceiver_PullsFromCallerMintsToReceiver() external {
        uint256 callerBefore = usdc.balanceOf(users.alice);

        vm.prank(users.alice);
        uint256 sharesOut = gateway.deposit(address(mockVault), ASSETS, MIN_SHARES_OUT, users.bob, PARTNER_ID);

        assertEq(usdc.balanceOf(users.alice), callerBefore - ASSETS);
        assertEq(mockVault.balanceOf(users.bob), sharesOut);
        assertEq(mockVault.balanceOf(users.alice), 0);
    }

    function test_WhenEmitsEvent() external {
        // Compute sharesOut directly via the vault preview to assert event payload.
        uint256 expected = mockVault.previewDeposit(ASSETS);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit IYoGateway.YoGatewayDeposit(PARTNER_ID, address(mockVault), users.alice, users.alice, ASSETS, expected);

        vm.prank(users.alice);
        gateway.deposit(address(mockVault), ASSETS, MIN_SHARES_OUT, users.alice, PARTNER_ID);
    }

    function test_RevertWhen_ZeroAssets() external {
        vm.prank(users.alice);
        vm.expectRevert(Errors.Gateway__ZeroAmount.selector);
        gateway.deposit(address(mockVault), 0, MIN_SHARES_OUT, users.alice, PARTNER_ID);
    }

    function test_RevertWhen_ZeroReceiver() external {
        vm.prank(users.alice);
        vm.expectRevert(Errors.Gateway__ZeroReceiver.selector);
        gateway.deposit(address(mockVault), ASSETS, MIN_SHARES_OUT, address(0), PARTNER_ID);
    }

    function test_RevertWhen_VaultNotAllowed() external {
        address fake = address(0xDEAD);
        vm.prank(users.alice);
        vm.expectRevert(Errors.Gateway__VaultNotAllowed.selector);
        gateway.deposit(fake, ASSETS, MIN_SHARES_OUT, users.alice, PARTNER_ID);
    }

    function test_RevertWhen_BelowMinSharesOut() external {
        uint256 expected = mockVault.previewDeposit(ASSETS);

        vm.prank(users.alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.Gateway__InsufficientSharesOut.selector, expected, expected + 1));
        gateway.deposit(address(mockVault), ASSETS, expected + 1, users.alice, PARTNER_ID);
    }
}
