// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Integration_Test } from "../../Integration.t.sol";

contract Stake_LidoAdapter_Integration_Fuzz_Test is Integration_Test {
    function setUp() public override {
        super.setUp();
        // Pre-fund vault with WETH.
        vm.deal(address(this), 1_000_000 ether);
        mockWETH.deposit{ value: 1_000_000 ether }();
        mockWETH.transfer(users.vault, 1_000_000 ether);
    }

    /// @dev Any positive `wethAmount` stakes 1:1 (mock) and leaves the adapter holding no balance.
    function testFuzz_Stake_PullsAndForwards(uint256 wethAmount) external {
        wethAmount = bound(wethAmount, 1, 100_000 ether);

        uint256 wethBefore = mockWETH.balanceOf(users.vault);
        uint256 stETHBefore = mockStETH.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 stETHReceived = lidoAdapter.stake(wethAmount);

        assertEq(stETHReceived, wethAmount, "1:1 stETH out");
        assertEq(mockWETH.balanceOf(users.vault), wethBefore - wethAmount, "WETH pulled");
        assertEq(mockStETH.balanceOf(users.vault), stETHBefore + wethAmount, "stETH delivered");

        // Custody invariants
        assertEq(address(lidoAdapter).balance, 0);
        assertEq(mockWETH.balanceOf(address(lidoAdapter)), 0);
        assertEq(mockStETH.balanceOf(address(lidoAdapter)), 0);
    }

    /// @dev requestUnstake mints an NFT and pulls stETH from the vault.
    function testFuzz_RequestUnstake_PullsStETHAndReturnsRequestId(uint256 amount) external {
        amount = bound(amount, 100, 100_000 ether);

        // First stake to get stETH.
        vm.prank(users.vault);
        lidoAdapter.stake(amount);

        uint256 stETHBefore = mockStETH.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 requestId = lidoAdapter.requestUnstake(amount);

        assertGt(requestId, 0, "requestId is set");
        assertEq(mockStETH.balanceOf(users.vault), stETHBefore - amount, "stETH pulled");
        assertEq(mockStETH.balanceOf(address(lidoAdapter)), 0, "adapter clean");
    }
}
