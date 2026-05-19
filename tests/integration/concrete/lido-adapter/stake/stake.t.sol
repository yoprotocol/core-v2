// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { IYoLidoAdapter } from "src/interfaces/IYoLidoAdapter.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract StakeLidoIntegrationConcreteTest is Integration_Test {
    function setUp() public override {
        super.setUp();
        // Pre-fund vault with WETH so it has something to stake.
        vm.deal(address(this), 100 ether);
        mockWETH.deposit{ value: 100 ether }();
        mockWETH.transfer(users.vault, 100 ether);
    }

    function test_RevertWhen_WethAmountZero() external whenCallerVault {
        vm.expectRevert(IYoLidoAdapter.InvalidAmount.selector);
        lidoAdapter.stake(0);
    }

    function test_RevertGiven_VaultHasNotApprovedAdapter() external whenAmountNotZero {
        vm.prank(users.vault);
        mockWETH.approve(address(lidoAdapter), 0);

        vm.prank(users.vault);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        lidoAdapter.stake(1 ether);
    }

    function test_GivenApproved_StakesAndForwardsStETH() external whenCallerVault whenAmountNotZero {
        uint256 amount = 10 ether;
        uint256 wethBefore = mockWETH.balanceOf(users.vault);
        uint256 stETHBefore = mockStETH.balanceOf(users.vault);

        uint256 stETHReceived = lidoAdapter.stake(amount);

        // 1:1 in our mock.
        assertEq(stETHReceived, amount, "stETHReceived");
        assertEq(mockWETH.balanceOf(users.vault), wethBefore - amount, "vault WETH out");
        assertEq(mockStETH.balanceOf(users.vault), stETHBefore + amount, "vault stETH in");

        // Custody invariants — adapter ends clean.
        assertEq(address(lidoAdapter).balance, 0, "adapter ETH");
        assertEq(mockWETH.balanceOf(address(lidoAdapter)), 0, "adapter WETH");
        assertEq(mockStETH.balanceOf(address(lidoAdapter)), 0, "adapter stETH");
    }

    function test_EmitsAdapterAction() external whenCallerVault whenAmountNotZero {
        uint256 amount = 10 ether;
        vm.expectEmit(true, true, true, true, address(lidoAdapter));
        emit YoAdapterBase.AdapterAction(
            users.vault,
            address(mockStETH),
            address(mockWETH),
            YoAdapterBase.AdapterDirection.Deposit,
            amount
        );
        lidoAdapter.stake(amount);
    }
}
