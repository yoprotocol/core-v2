// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoMidnightRegistry } from "src/interfaces/IYoMidnightRegistry.sol";
import { YoMidnightRegistry } from "src/registries/YoMidnightRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract RenounceOwnership_MidnightRegistry_Integration_Concrete_Test is Integration_Test {
    YoMidnightRegistry internal midnightRegistry;

    function setUp() public override {
        Integration_Test.setUp();
        midnightRegistry = new YoMidnightRegistry(users.owner);
    }

    function test_WhenCallerNotOwner() external {
        vm.prank(users.eve);
        vm.expectRevert(IYoMidnightRegistry.RenounceDisabled.selector);
        midnightRegistry.renounceOwnership();
    }

    function test_WhenCallerOwner() external whenCallerOwner {
        vm.expectRevert(IYoMidnightRegistry.RenounceDisabled.selector);
        midnightRegistry.renounceOwnership();

        assertEq(midnightRegistry.owner(), users.owner, "owner");
    }
}
