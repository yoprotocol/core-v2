// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { MockOneInchRouter } from "../../../mocks/MockOneInchRouter.sol";
import { Integration_Test } from "../../Integration.t.sol";

/// @notice Regression for the audit finding: pre-existing `tokenIn` dust at the adapter address
///         must NOT permanently DoS swaps for that input token.
contract DustDoSSwapAdapterIntegrationFuzzTest is Integration_Test {
    function _execCalldata(uint256 amountIn) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(MockOneInchRouter.execute.selector, amountIn);
    }

    function testFuzz_PreExistingDust_DoesNotBlockSwap(uint256 dust, uint256 amountIn) external {
        dust = bound(dust, 1, 1000e6);
        amountIn = bound(amountIn, 1, 100_000e6);

        usdc.mint(address(swapAdapter), dust); // adversary dusts the adapter

        usdt.mint(address(mockAggregator), amountIn);
        mockAggregator.setSwap(address(usdc), address(usdt), amountIn, address(swapAdapter));

        vm.prank(users.vault);
        swapAdapter.swap(address(usdc), address(usdt), amountIn, amountIn, type(uint256).max, _execCalldata(amountIn));

        assertEq(usdc.balanceOf(address(swapAdapter)), dust, "dust untouched");
    }
}
