// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/src/Test.sol";

import { IAggregatorV3 } from "src/interfaces/external/IAggregatorV3.sol";
import { ChainlinkCompositeAggregator } from "src/oracles/ChainlinkCompositeAggregator.sol";

contract MockAggregator is IAggregatorV3 {
    uint8 internal _dec;
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint80 internal _roundId;
    uint80 internal _answeredInRound;

    constructor(uint8 dec_, int256 answer_, uint256 updatedAt_, uint80 roundId_, uint80 answeredInRound_) {
        _dec = dec_;
        _answer = answer_;
        _updatedAt = updatedAt_;
        _roundId = roundId_;
        _answeredInRound = answeredInRound_;
    }

    function decimals() external view returns (uint8) {
        return _dec;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _updatedAt, _updatedAt, _answeredInRound);
    }
}

contract ChainlinkCompositeAggregatorTest is Test {
    // WSTETH/ETH = 1.2 (18 dec), ETH/USD = 1672 (8 dec) -> wstETH/USD = 2006.4 (8 dec).
    int256 internal constant WSTETH_ETH = 1.2e18;
    int256 internal constant ETH_USD = 1672e8;
    int256 internal constant EXPECTED = 2006.4e8;

    function _composite(MockAggregator mul, MockAggregator base) internal returns (ChainlinkCompositeAggregator) {
        return new ChainlinkCompositeAggregator(mul, base, 8, "WSTETH / USD (composite)");
    }

    function test_DecimalsAndComposedAnswer() external {
        MockAggregator mul = new MockAggregator(18, WSTETH_ETH, 1000, 1, 1);
        MockAggregator base = new MockAggregator(8, ETH_USD, 2000, 1, 1);
        ChainlinkCompositeAggregator c = _composite(mul, base);

        assertEq(c.decimals(), 8, "decimals");
        (, int256 answer,, uint256 updatedAt,) = c.latestRoundData();
        assertEq(answer, EXPECTED, "composed answer");
        assertEq(updatedAt, 1000, "updatedAt = older leg");
    }

    function test_RevertWhen_LegNonPositive() external {
        MockAggregator mul = new MockAggregator(18, 0, 1000, 1, 1);
        MockAggregator base = new MockAggregator(8, ETH_USD, 2000, 1, 1);
        ChainlinkCompositeAggregator c = _composite(mul, base);
        vm.expectRevert(ChainlinkCompositeAggregator.NonPositivePrice.selector);
        c.latestRoundData();
    }

    function test_RevertWhen_RoundIncomplete() external {
        MockAggregator mul = new MockAggregator(18, WSTETH_ETH, 1000, 5, 4);
        MockAggregator base = new MockAggregator(8, ETH_USD, 2000, 1, 1);
        ChainlinkCompositeAggregator c = _composite(mul, base);
        vm.expectRevert(ChainlinkCompositeAggregator.IncompleteRound.selector);
        c.latestRoundData();
    }

    function test_RevertWhen_OutputDecimalsTooHigh() external {
        MockAggregator mul = new MockAggregator(8, WSTETH_ETH, 1000, 1, 1);
        MockAggregator base = new MockAggregator(8, ETH_USD, 2000, 1, 1);
        vm.expectRevert();
        new ChainlinkCompositeAggregator(mul, base, 18, "bad");
    }
}
