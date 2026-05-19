// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoSwapAdapter } from "src/interfaces/IYoSwapAdapter.sol";
import { IYoSwapPairRegistry } from "src/interfaces/IYoSwapPairRegistry.sol";

import { MockOneInchRouter } from "../../../mocks/MockOneInchRouter.sol";
import { Integration_Test } from "../../Integration.t.sol";

contract OperatorTrustedSwapAdapterIntegrationFuzzTest is Integration_Test {
    function _execCalldata(uint256 amountIn) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(MockOneInchRouter.execute.selector, amountIn);
    }

    /// @dev OPERATOR_TRUSTED mode skips the oracle floor entirely. The only on-chain constraint
    ///      is `amountOut >= minOut`, so any `minOut <= amountIn` (1:1 mock) succeeds, and any
    ///      `minOut > amountIn` reverts with InsufficientOutput — irrespective of oracle quote.
    function testFuzz_OperatorTrusted_SkipsOracleFloor(uint256 amountIn, uint256 minOut) external {
        amountIn = bound(amountIn, 1, 100_000e6);
        minOut = bound(minOut, 0, amountIn * 2);

        // Flip the pair to OPERATOR_TRUSTED.
        vm.prank(users.owner);
        pairRegistry.setMode(users.vault, address(usdc), address(usdt), IYoSwapPairRegistry.PairMode.OPERATOR_TRUSTED);

        usdt.mint(address(mockAggregator), amountIn);
        mockAggregator.setSwap(address(usdc), address(usdt), amountIn, address(swapAdapter));

        if (minOut > amountIn) {
            vm.prank(users.vault);
            vm.expectRevert(abi.encodeWithSelector(IYoSwapAdapter.InsufficientOutput.selector, amountIn, minOut));
            swapAdapter.swap(address(usdc), address(usdt), amountIn, minOut, type(uint256).max, _execCalldata(amountIn));
        } else {
            uint256 vaultUsdtBefore = usdt.balanceOf(users.vault);
            vm.prank(users.vault);
            uint256 amountOut = swapAdapter.swap(
                address(usdc), address(usdt), amountIn, minOut, type(uint256).max, _execCalldata(amountIn)
            );
            assertGe(amountOut, minOut);
            assertEq(usdt.balanceOf(users.vault), vaultUsdtBefore + amountIn);
        }

        // Adapter ends clean regardless of branch.
        assertZeroBalance(address(usdc), address(swapAdapter));
        assertZeroBalance(address(usdt), address(swapAdapter));
        assertZeroAllowance(address(usdc), address(swapAdapter), address(mockAggregator));
    }
}
