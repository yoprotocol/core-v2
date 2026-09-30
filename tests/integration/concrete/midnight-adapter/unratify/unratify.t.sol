// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";

import { MidnightAdapter_Integration_Concrete_Test } from "../MidnightAdapter.t.sol";

contract Unratify_Integration_Concrete_Test is MidnightAdapter_Integration_Concrete_Test {
    bytes32 internal root;

    function setUp() public override {
        MidnightAdapter_Integration_Concrete_Test.setUp();
        vm.prank(users.vault);
        root = midnightAdapter.ratify(_offers(_offer(), 1));
    }

    function test_GivenAdapterNotAuthorizedOnMidnight() external whenCallerVault {
        mockMidnight.setIsAuthorized(address(midnightAdapter), false, users.vault);

        vm.expectRevert(bytes("unauthorized"));
        midnightAdapter.unratify(root);
    }

    function test_GivenAdapterAuthorizedOnMidnight() external whenCallerVault {
        vm.expectEmit(address(midnightAdapter));
        emit YoMidnightAdapter.MidnightRootSet(users.vault, root, false, 0);

        midnightAdapter.unratify(root);

        assertFalse(mockRatifier.isRootRatified(users.vault, root), "ratified");
    }
}
