// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoToken } from "src/YoToken.sol";

import { YoTokenBase_Test } from "../YoTokenBase.t.sol";

contract InitializeIntegrationConcreteTest is YoTokenBase_Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;

    function test_WhenInitialized_SetsMetadataAndMints() external view {
        assertEq(token.name(), "YoToken");
        assertEq(token.symbol(), "YO");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(users.owner), INITIAL_SUPPLY);
    }

    function test_RevertWhen_InitializeCalledTwice() external {
        vm.expectRevert();
        token.initialize(users.owner, "YoToken", "YO");
    }

    function test_RevertWhen_InitializeOnImplementation() external {
        YoToken impl = new YoToken();
        vm.expectRevert();
        impl.initialize(users.owner, "YoToken", "YO");
    }
}
