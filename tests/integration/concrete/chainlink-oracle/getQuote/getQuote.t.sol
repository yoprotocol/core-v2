// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoSwapOracle } from "src/interfaces/IYoSwapOracle.sol";

import { ChainlinkOracleBase_Test } from "../ChainlinkOracleBase.t.sol";

contract GetQuoteIntegrationConcreteTest is ChainlinkOracleBase_Test {
    function test_RevertGiven_TokenInUnconfigured() external {
        _configureWithPrice(address(usdt), 1e8);
        vm.expectRevert(abi.encodeWithSelector(IYoSwapOracle.UnknownPair.selector, address(usdc), address(usdt)));
        oracle.getQuote(address(usdc), address(usdt), 1e6);
    }

    function test_RevertGiven_TokenOutUnconfigured() external {
        _configureWithPrice(address(usdc), 1e8);
        vm.expectRevert(abi.encodeWithSelector(IYoSwapOracle.UnknownPair.selector, address(usdc), address(usdt)));
        oracle.getQuote(address(usdc), address(usdt), 1e6);
    }

    function test_GivenSameDecimals_PricesEqual_ReturnsAmountIn() external {
        _configureWithPrice(address(usdc), 1e8); // $1
        _configureWithPrice(address(usdt), 1e8); // $1
        assertEq(oracle.getQuote(address(usdc), address(usdt), 1_000_000e6), 1_000_000e6);
    }

    function test_GivenSameDecimals_TokenInHalfPrice_ReturnsHalfAmount() external {
        _configureWithPrice(address(usdc), 0.5e8); // $0.50
        _configureWithPrice(address(usdt), 1e8); // $1.00
        assertEq(oracle.getQuote(address(usdc), address(usdt), 100e6), 50e6);
    }

    function test_GivenTokenInFewerDecimals_ScalesUp() external {
        // tokenIn: 6 dec ($1), tokenOut: 18 dec ($1). 1e6 of in → 1e18 of out.
        _configureWithPrice(address(usdc), 1e8);
        _configureWithPrice(address(weth), 1e8);
        assertEq(oracle.getQuote(address(usdc), address(weth), 1e6), 1e18);
    }

    function test_GivenTokenInMoreDecimals_ScalesDown() external {
        _configureWithPrice(address(weth), 1e8);
        _configureWithPrice(address(usdc), 1e8);
        assertEq(oracle.getQuote(address(weth), address(usdc), 1e18), 1e6);
    }
}
