// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { MockAggregatorV3 } from "../../../mocks/MockAggregatorV3.sol";
import { ChainlinkOracleBase_Test } from "../../concrete/chainlink-oracle/ChainlinkOracleBase.t.sol";

contract GetQuote_ChainlinkOracle_Integration_Fuzz_Test is ChainlinkOracleBase_Test {
    /// @dev For any two prices and amounts (held in safe bands so the multiplication does not
    ///      overflow), getQuote must equal the closed-form math the contract documents:
    ///      amountOut = amountIn * pIn * 10^outDec / (pOut * 10^inDec).
    function testFuzz_GetQuote_MatchesClosedForm(uint256 priceIn, uint256 priceOut, uint256 amountIn) external {
        // Aggregators are 8 decimals in our mocks. Cap so amountIn * pIn ≤ 2^192.
        priceIn = bound(priceIn, 1, 1e10);
        priceOut = bound(priceOut, 1, 1e10);
        amountIn = bound(amountIn, 1, 1e20);

        MockAggregatorV3 feedIn = new MockAggregatorV3(8);
        MockAggregatorV3 feedOut = new MockAggregatorV3(8);
        feedIn.setPrice(int256(priceIn));
        feedOut.setPrice(int256(priceOut));

        // Use the two stable mock-USD tokens already deployed in the test fixture (both 6 dec).
        _configure(address(usdc), address(feedIn), 1 hours);
        _configure(address(usdt), address(feedOut), 1 hours);

        uint256 actual = oracle.getQuote(address(usdc), address(usdt), amountIn);

        // Same-decimals path:
        //   1e18-scaled pIn  = priceIn  * 1e10
        //   1e18-scaled pOut = priceOut * 1e10
        //   amountOut = amountIn * pIn / pOut  (decimals cancel)
        uint256 pInScaled = priceIn * 1e10;
        uint256 pOutScaled = priceOut * 1e10;
        uint256 expected = Math.mulDiv(amountIn * pInScaled, 1, pOutScaled);
        assertEq(actual, expected, "quote matches closed form");
    }

    /// @dev Same-asset quote should always echo `amountIn` (priceIn / priceOut cancel, decimals match).
    function testFuzz_GetQuote_SameAsset_EchoesAmount(uint256 price, uint256 amountIn) external {
        price = bound(price, 1, 1e10);
        amountIn = bound(amountIn, 1, 1e20);

        MockAggregatorV3 feed = new MockAggregatorV3(8);
        feed.setPrice(int256(price));
        _configure(address(usdc), address(feed), 1 hours);

        assertEq(oracle.getQuote(address(usdc), address(usdc), amountIn), amountIn);
    }

    /// @dev Doubling the input price doubles the output up to floor-rounding (±1 wei) —
    ///      `Math.mulDiv` rounds down, so `floor(2·x/y) ∈ {2·floor(x/y), 2·floor(x/y) + 1}`.
    function testFuzz_GetQuote_LinearInPriceIn(uint256 priceIn, uint256 amountIn) external {
        priceIn = bound(priceIn, 1, 1e9);
        amountIn = bound(amountIn, 1, 1e20);

        MockAggregatorV3 feedIn = new MockAggregatorV3(8);
        MockAggregatorV3 feedOut = new MockAggregatorV3(8);
        feedIn.setPrice(int256(priceIn));
        feedOut.setPrice(1e8); // 1.00 USD
        _configure(address(usdc), address(feedIn), 1 hours);
        _configure(address(usdt), address(feedOut), 1 hours);

        uint256 baseline = oracle.getQuote(address(usdc), address(usdt), amountIn);
        feedIn.setPrice(int256(priceIn * 2));
        uint256 doubled = oracle.getQuote(address(usdc), address(usdt), amountIn);

        uint256 expected = baseline * 2;
        uint256 diff = doubled > expected ? doubled - expected : expected - doubled;
        assertLe(diff, 1, "linearity within 1-wei floor rounding");
    }
}
