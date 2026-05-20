// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/src/Test.sol";

import { YoSwapAdapter } from "src/adapters/swap/YoSwapAdapter.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockOneInchRouter } from "../../mocks/MockOneInchRouter.sol";
import { MockSwapOracle } from "../../mocks/MockSwapOracle.sol";
import { Store } from "../stores/Store.sol";

contract SwapAdapterHandler is Test {
    YoSwapAdapter internal adapter;
    address internal vault;
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;
    MockOneInchRouter internal aggregator;
    MockSwapOracle internal oracle;
    Store internal store;

    constructor(
        YoSwapAdapter _adapter,
        address _vault,
        MockERC20 _in,
        MockERC20 _out,
        MockOneInchRouter _aggregator,
        MockSwapOracle _oracle,
        Store _store
    ) {
        adapter = _adapter;
        vault = _vault;
        tokenIn = _in;
        tokenOut = _out;
        aggregator = _aggregator;
        oracle = _oracle;
        store = _store;
    }

    function swap(uint256 amountIn) external {
        amountIn = bound(amountIn, 1, 100_000e6);
        if (tokenIn.balanceOf(vault) < amountIn) {
            tokenIn.mint(vault, amountIn);
        }

        uint256 expectedOut = amountIn;
        tokenOut.mint(address(aggregator), expectedOut);
        aggregator.setSwap(address(tokenIn), address(tokenOut), expectedOut, address(adapter));

        uint256 vaultOutBefore = tokenOut.balanceOf(vault);

        vm.prank(vault);
        try adapter.swap(
            address(tokenIn),
            address(tokenOut),
            amountIn,
            expectedOut,
            type(uint256).max,
            abi.encodeWithSelector(MockOneInchRouter.execute.selector, amountIn)
        ) returns (
            uint256 out
        ) {
            store.recordSwap(amountIn, out);
            // The reported `amountOut` must match the vault-side delta.
            uint256 vaultOutAfter = tokenOut.balanceOf(vault);
            if (vaultOutAfter - vaultOutBefore != out) {
                store.flagSwapOutputViolation();
            }
        } catch { }
    }
}
