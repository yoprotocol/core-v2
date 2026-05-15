// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoOracle } from "src/interfaces/IYoOracle.sol";
import { YoOracle } from "src/YoOracle.sol";

import { YoOracleBase_Test } from "../YoOracleBase.t.sol";

contract ConstructorIntegrationConcreteTest is YoOracleBase_Test {
    function test_WhenConstructed_SetsState() external view {
        assertEq(oracle.DEFAULT_WINDOW_SECONDS(), DEFAULT_WINDOW);
        assertEq(oracle.DEFAULT_MAX_CHANGE_BPS(), DEFAULT_MAX_CHANGE_BPS);
        assertEq(oracle.updater(), users.operator);
        assertEq(oracle.owner(), users.owner);
    }

    function test_RevertWhen_UpdaterZero() external {
        vm.expectRevert(IYoOracle.InvalidConfig.selector);
        new YoOracle(address(0), DEFAULT_WINDOW, DEFAULT_MAX_CHANGE_BPS);
    }
}
