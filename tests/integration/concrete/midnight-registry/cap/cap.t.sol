// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoMidnightRegistry } from "src/registries/YoMidnightRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract Cap_MidnightRegistry_Integration_Concrete_Test is Integration_Test {
    uint256 internal constant CAP = 20_000e6;

    YoMidnightRegistry internal midnightRegistry;

    function setUp() public override {
        Integration_Test.setUp();
        midnightRegistry = new YoMidnightRegistry(users.owner);
    }

    function test_GivenCapNotSet() external view {
        assertEq(midnightRegistry.cap(users.vault), 0, "cap");
    }

    function test_GivenCapSet() external {
        vm.prank(users.owner);
        midnightRegistry.setCap(users.vault, CAP);

        assertEq(midnightRegistry.cap(users.vault), CAP, "cap");
        assertEq(midnightRegistry.cap(users.eve), 0, "other vault");
    }
}
