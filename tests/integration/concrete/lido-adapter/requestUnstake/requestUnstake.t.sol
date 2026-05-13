// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { IYoLidoAdapter } from "src/interfaces/IYoLidoAdapter.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract RequestUnstakeLidoIntegrationConcreteTest is Integration_Test {
    function setUp() public override {
        super.setUp();
        // Pre-seed vault with stETH.
        mockStETH.mintForTest(users.vault, 100 ether);
    }

    function test_RevertWhen_StETHAmountZero() external whenCallerVault {
        vm.expectRevert(IYoLidoAdapter.InvalidAmount.selector);
        lidoAdapter.requestUnstake(0);
    }

    function test_RevertGiven_VaultHasNotApprovedAdapter() external whenAmountNotZero {
        vm.prank(users.vault);
        mockStETH.approve(address(lidoAdapter), 0);

        vm.prank(users.vault);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        lidoAdapter.requestUnstake(1 ether);
    }

    function test_GivenApproved_PullsAndQueues() external whenCallerVault whenAmountNotZero {
        uint256 amount = 10 ether;
        uint256 stETHBefore = mockStETH.balanceOf(users.vault);

        uint256 requestId = lidoAdapter.requestUnstake(amount);

        assertGt(requestId, 0, "requestId");
        assertEq(mockLidoQueue.ownerOf(requestId), users.vault, "vault owns NFT");
        assertEq(mockStETH.balanceOf(users.vault), stETHBefore - amount, "vault stETH out");

        // stETH ends up in the queue, not the adapter.
        assertEq(mockStETH.balanceOf(address(lidoAdapter)), 0, "adapter stETH");
        assertEq(mockStETH.allowance(address(lidoAdapter), address(mockLidoQueue)), 0, "queue allow");
    }
}
