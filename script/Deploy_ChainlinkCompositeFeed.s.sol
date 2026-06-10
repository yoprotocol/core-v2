// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { IAggregatorV3 } from "../src/interfaces/external/IAggregatorV3.sol";
import { ChainlinkCompositeAggregator } from "../src/oracles/ChainlinkCompositeAggregator.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys a {ChainlinkCompositeAggregator} that synthesizes `feedMul × feedBase`, for use
///         as a {YoChainlinkOracle} asset feed where no native single feed exists.
///
///         Canonical case — **wstETH/USD on Base** (no direct feed): compose `WSTETH/ETH × ETH/USD`.
///           FEED_MUL  = 0x43a5C292A453A3bF3606fa856197f09D7B74251a  (WSTETH/ETH, Base)
///           FEED_BASE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70  (ETH/USD,    Base)
///           OUTPUT_DECIMALS = 8, FEED_DESCRIPTION = "WSTETH / USD (composite)"
///
///         Required env vars:
///           - FEED_MUL:  Chainlink feed multiplied into the result.
///           - FEED_BASE: Chainlink feed that rebases the result into its output unit.
///
///         Optional env vars:
///           - OUTPUT_DECIMALS:  decimals the adapter reports (default 8, matching USD feeds).
///           - FEED_DESCRIPTION: human label (default "Composite (mul x base)").
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}).
contract Deploy_ChainlinkCompositeFeed is BaseScript {
    error FeedNotDeployed(address feed);

    function run() public broadcast returns (ChainlinkCompositeAggregator feed) {
        address feedMul = vm.envAddress("FEED_MUL");
        address feedBase = vm.envAddress("FEED_BASE");
        if (feedMul.code.length == 0) {
            revert FeedNotDeployed(feedMul);
        }
        if (feedBase.code.length == 0) {
            revert FeedNotDeployed(feedBase);
        }

        uint8 outputDecimals = uint8(vm.envOr({ name: "OUTPUT_DECIMALS", defaultValue: uint256(8) }));
        string memory description =
            vm.envOr({ name: "FEED_DESCRIPTION", defaultValue: string("Composite (mul x base)") });

        feed = new ChainlinkCompositeAggregator{ salt: SALT }(
            IAggregatorV3(feedMul), IAggregatorV3(feedBase), outputDecimals, description
        );

        _log(feed, feedMul, feedBase, outputDecimals, description);
    }

    function _log(
        ChainlinkCompositeAggregator feed,
        address feedMul,
        address feedBase,
        uint8 outputDecimals,
        string memory description
    )
        internal
        view
    {
        console2.log("=== Chainlink Composite Feed Deployed ===");
        console2.log("Chain ID:        ", chainId);
        console2.log("Feed:            ", address(feed));
        console2.log("Description:     ", description);
        console2.log("Decimals:        ", outputDecimals);
        console2.log("feedMul:         ", feedMul);
        console2.log("feedBase:        ", feedBase);
    }
}
