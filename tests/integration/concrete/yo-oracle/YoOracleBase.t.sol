// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoOracle } from "src/YoOracle.sol";

import { Integration_Test } from "../../Integration.t.sol";

/// @notice Shared base for `YoOracle` BTT tests. Deploys a fresh oracle owned by `users.owner`
///         with `users.operator` as the updater. Tests can override window / max-change defaults
///         via `_redeployOracle`.
abstract contract YoOracleBase_Test is Integration_Test {
    uint64 internal constant DEFAULT_WINDOW = 1 days;
    uint64 internal constant DEFAULT_MAX_CHANGE_BPS = 1_000_000; // 0.1% over 1e9
    uint64 internal constant BPS_DENOMINATOR = 1_000_000_000;

    YoOracle internal oracle;

    function _redeployOracle(address updater, uint64 windowSec, uint64 maxChangeBps) internal {
        vm.prank(users.owner);
        oracle = new YoOracle(updater, windowSec, maxChangeBps);
        vm.label(address(oracle), "YoOracle");
    }

    function setUp() public virtual override {
        super.setUp();
        _redeployOracle(users.operator, DEFAULT_WINDOW, DEFAULT_MAX_CHANGE_BPS);
    }
}
