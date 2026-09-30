// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";
import { IMorpho } from "src/interfaces/IMorpho.sol";
import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";
import { IYoMorphoMarketRegistry } from "src/interfaces/IYoMorphoMarketRegistry.sol";
import { IMidnight } from "src/vendor/morpho-midnight/interfaces/IMidnight.sol";
import {
    IBlueBuyCallbackFactory
} from "src/vendor/morpho-midnight/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import { ISetterRatifier } from "src/vendor/morpho-midnight/ratifiers/interfaces/ISetterRatifier.sol";

import { MockBlueBuyCallbackFactory, MockSetterRatifier } from "../../../../mocks/MockMidnight.sol";
import { MidnightAdapter_Integration_Concrete_Test } from "../MidnightAdapter.t.sol";

contract Constructor_Integration_Concrete_Test is MidnightAdapter_Integration_Concrete_Test {
    function test_WhenRegistryZero() external {
        vm.expectRevert(IYoMidnightAdapter.InvalidConfig.selector);
        new YoMidnightAdapter(
            IMorpho(address(mockMorpho)),
            IMidnight(address(mockMidnight)),
            ISetterRatifier(address(mockRatifier)),
            IBlueBuyCallbackFactory(address(mockCallbackFactory)),
            IYoMorphoMarketRegistry(address(0)),
            MAX_TIME_TO_MATURITY,
            MAX_CONTINUOUS_FEE_CAP,
            yoRegistry
        );
    }

    function test_WhenMaxTimeToMaturityZero() external {
        vm.expectRevert(IYoMidnightAdapter.InvalidConfig.selector);
        new YoMidnightAdapter(
            IMorpho(address(mockMorpho)),
            IMidnight(address(mockMidnight)),
            ISetterRatifier(address(mockRatifier)),
            IBlueBuyCallbackFactory(address(mockCallbackFactory)),
            marketRegistry,
            0,
            MAX_CONTINUOUS_FEE_CAP,
            yoRegistry
        );
    }

    function test_WhenRatifierPointsToAnotherMidnight() external {
        MockSetterRatifier otherRatifier = new MockSetterRatifier(makeAddr("OtherMidnight"));
        vm.expectRevert(IYoMidnightAdapter.InvalidConfig.selector);
        _deployAdapter(
            IMorpho(address(mockMorpho)),
            IMidnight(address(mockMidnight)),
            ISetterRatifier(address(otherRatifier)),
            IBlueBuyCallbackFactory(address(mockCallbackFactory))
        );
    }

    function test_WhenCallbackFactoryPointsToAnotherMidnight() external {
        MockBlueBuyCallbackFactory otherFactory =
            new MockBlueBuyCallbackFactory(makeAddr("OtherMidnight"), address(mockMorpho));
        vm.expectRevert(IYoMidnightAdapter.InvalidConfig.selector);
        _deployAdapter(
            IMorpho(address(mockMorpho)),
            IMidnight(address(mockMidnight)),
            ISetterRatifier(address(mockRatifier)),
            IBlueBuyCallbackFactory(address(otherFactory))
        );
    }

    function test_WhenCallbackFactoryPointsToAnotherBlue() external {
        MockBlueBuyCallbackFactory otherFactory =
            new MockBlueBuyCallbackFactory(address(mockMidnight), makeAddr("OtherBlue"));
        vm.expectRevert(IYoMidnightAdapter.InvalidConfig.selector);
        _deployAdapter(
            IMorpho(address(mockMorpho)),
            IMidnight(address(mockMidnight)),
            ISetterRatifier(address(mockRatifier)),
            IBlueBuyCallbackFactory(address(otherFactory))
        );
    }

    function test_WhenConfigConsistent() external view {
        assertEq(address(midnightAdapter.morpho()), address(mockMorpho), "morpho");
        assertEq(address(midnightAdapter.midnight()), address(mockMidnight), "midnight");
        assertEq(address(midnightAdapter.ratifier()), address(mockRatifier), "ratifier");
        assertEq(address(midnightAdapter.callbackFactory()), address(mockCallbackFactory), "callbackFactory");
        assertEq(address(midnightAdapter.registry()), address(marketRegistry), "registry");
        assertEq(midnightAdapter.maxTimeToMaturity(), MAX_TIME_TO_MATURITY, "maxTimeToMaturity");
        assertEq(midnightAdapter.maxContinuousFeeCap(), MAX_CONTINUOUS_FEE_CAP, "maxContinuousFeeCap");
        assertEq(address(midnightAdapter.yoRegistry()), address(yoRegistry), "yoRegistry");
    }
}
