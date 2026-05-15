// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Integration_Test } from "../../Integration.t.sol";

/// @notice Regression for the audit finding: pre-existing dust at the adapter address (selfdestruct
///         of 1 wei of ETH, or 1 wei WETH transfer) must NOT permanently DoS the Lido flows. The
///         snapshot/delta check only rejects what *this call* leaks.
contract DustDoS_LidoAdapter_Integration_Fuzz_Test is Integration_Test {
    function setUp() public override {
        super.setUp();
        // Pre-fund the vault with WETH for staking.
        vm.deal(address(this), 1_000_000 ether);
        mockWETH.deposit{ value: 1_000_000 ether }();
        IERC20(address(mockWETH)).transfer(users.vault, 100 ether);
    }

    function testFuzz_PreExistingDust_DoesNotBlockStake(
        uint256 ethDust,
        uint256 wethDust,
        uint256 wethAmount
    )
        external
    {
        ethDust = bound(ethDust, 1, 1 ether);
        wethDust = bound(wethDust, 1, 1 ether);
        wethAmount = bound(wethAmount, 1, 10 ether);

        // Adversary dusts the adapter with both ETH (simulated; selfdestruct on a fork would do
        // this for real) and WETH.
        vm.deal(address(lidoAdapter), ethDust);
        IERC20(address(mockWETH)).transfer(address(lidoAdapter), wethDust);

        vm.prank(users.vault);
        lidoAdapter.stake(wethAmount);

        // Dust still parked.
        assertEq(address(lidoAdapter).balance, ethDust, "ETH dust untouched");
        assertEq(IERC20(address(mockWETH)).balanceOf(address(lidoAdapter)), wethDust, "WETH dust untouched");
    }

    function testFuzz_PreExistingDust_DoesNotBlockClaim(uint256 ethDust, uint256 wethDust, uint256 amount) external {
        ethDust = bound(ethDust, 1, 1 ether);
        wethDust = bound(wethDust, 1, 1 ether);
        amount = bound(amount, 100, 50 ether);

        // First stake + request unstake to set up a finalizable request.
        vm.startPrank(users.vault);
        lidoAdapter.stake(amount);
        uint256 requestId = lidoAdapter.requestUnstake(amount);
        vm.stopPrank();

        // Finalize the request on the mock so claim can settle.
        mockLidoQueue.finalize(requestId, uint128(amount));

        // NOW dust the adapter.
        vm.deal(address(lidoAdapter), ethDust);
        IERC20(address(mockWETH)).transfer(address(lidoAdapter), wethDust);

        vm.prank(users.vault);
        lidoAdapter.claimUnstake(requestId);

        // Dust still parked.
        assertEq(address(lidoAdapter).balance, ethDust, "ETH dust untouched");
        assertEq(IERC20(address(mockWETH)).balanceOf(address(lidoAdapter)), wethDust, "WETH dust untouched");
    }
}
