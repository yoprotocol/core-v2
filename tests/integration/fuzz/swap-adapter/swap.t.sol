// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoSwapAdapter } from "src/interfaces/IYoSwapAdapter.sol";

import { MockOneInchRouter } from "../../../mocks/MockOneInchRouter.sol";
import { Integration_Test } from "../../Integration.t.sol";

contract SwapIntegrationFuzzTest is Integration_Test {
    uint256 private constant FUZZ_MIN = 1;
    uint256 private constant FUZZ_MAX = 100_000e6;

    function _execCalldata(uint256 amountIn) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(MockOneInchRouter.execute.selector, amountIn);
    }

    /// @dev For any random `amountIn` and `minOut`, the adapter must either succeed (and observe
    ///      `tokenOut delta >= minOut`) or revert with `SlippageTooLow`/`InsufficientOutput`.
    function testFuzz_Swap_OracleFloorEnforced(uint256 amountIn, uint256 minOut) external {
        amountIn = bound(amountIn, FUZZ_MIN, FUZZ_MAX);
        // Cap `minOut` at `amountIn` so the 1:1 aggregator can satisfy it. We're testing the
        // slippage-floor branch, not the insufficient-output branch (which is covered by the
        // concrete suite).
        minOut = bound(minOut, 0, amountIn);

        uint256 floor =
            (amountIn * (defaults.BPS_DENOMINATOR() - defaults.MAX_SLIPPAGE_BPS())) / defaults.BPS_DENOMINATOR();

        // Aggregator delivers `amountIn` (1:1).
        usdt.mint(address(mockAggregator), amountIn);
        mockAggregator.setSwap(address(usdc), address(usdt), amountIn, address(swapAdapter));

        if (minOut < floor) {
            vm.prank(users.vault);
            vm.expectRevert(abi.encodeWithSelector(IYoSwapAdapter.SlippageTooLow.selector, minOut, floor));
            swapAdapter.swap(address(usdc), address(usdt), amountIn, minOut, type(uint256).max, _execCalldata(amountIn));
        } else {
            uint256 vaultUsdtBefore = usdt.balanceOf(users.vault);
            // Prank IMMEDIATELY before the swap — `vm.prank` only applies to the next external call,
            // and any view call (e.g. balanceOf) before it would consume the prank.
            vm.prank(users.vault);
            uint256 amountOut = swapAdapter.swap(
                address(usdc), address(usdt), amountIn, minOut, type(uint256).max, _execCalldata(amountIn)
            );
            assertGe(amountOut, minOut, "amountOut >= minOut");
            assertEq(usdt.balanceOf(users.vault), vaultUsdtBefore + amountIn, "vault USDT delta");
        }
    }

    /// @dev After every successful swap, the adapter must hold zero `tokenIn`/`tokenOut` and zero
    ///      allowance to the aggregator. Tests the custody invariant under random inputs.
    function testFuzz_Swap_AdapterEndsClean(uint256 amountIn) external {
        amountIn = bound(amountIn, FUZZ_MIN, FUZZ_MAX);

        usdt.mint(address(mockAggregator), amountIn);
        mockAggregator.setSwap(address(usdc), address(usdt), amountIn, address(swapAdapter));

        vm.prank(users.vault);
        swapAdapter.swap(address(usdc), address(usdt), amountIn, amountIn, type(uint256).max, _execCalldata(amountIn));

        assertZeroBalance(address(usdc), address(swapAdapter));
        assertZeroBalance(address(usdt), address(swapAdapter));
        assertZeroAllowance(address(usdc), address(swapAdapter), address(mockAggregator));
    }
}
