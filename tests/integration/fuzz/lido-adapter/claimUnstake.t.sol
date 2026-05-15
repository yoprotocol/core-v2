// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Integration_Test } from "../../Integration.t.sol";

contract ClaimUnstake_LidoAdapter_Integration_Fuzz_Test is Integration_Test {
    function setUp() public override {
        super.setUp();
        vm.deal(address(this), 1_000_000 ether);
        mockWETH.deposit{ value: 1_000_000 ether }();
        mockWETH.transfer(users.vault, 1_000_000 ether);
    }

    /// @dev stake → requestUnstake → claimUnstake is a lossless round-trip on the 1:1 mock.
    function testFuzz_FullCycle_Lossless(uint256 amount) external {
        // Mock withdrawal queue is pre-funded with 1_000 ETH in Base.setUp; stay strictly under.
        amount = bound(amount, 100, 900 ether);

        uint256 wethBefore = mockWETH.balanceOf(users.vault);

        vm.startPrank(users.vault);
        lidoAdapter.stake(amount);
        uint256 requestId = lidoAdapter.requestUnstake(amount);
        vm.stopPrank();

        // Operator-side: finalize the request at the same ETH amount (test-only on the mock).
        mockLidoQueue.finalize(requestId, uint128(amount));

        vm.prank(users.vault);
        uint256 wethBack = lidoAdapter.claimUnstake(requestId);

        // 1:1 round-trip
        assertEq(wethBack, amount, "WETH back == amount staked");
        assertEq(mockWETH.balanceOf(users.vault), wethBefore, "vault WETH restored");

        // Adapter ends clean
        assertEq(address(lidoAdapter).balance, 0);
        assertEq(IERC20(address(mockWETH)).balanceOf(address(lidoAdapter)), 0);
        assertEq(mockStETH.balanceOf(address(lidoAdapter)), 0);
    }
}
