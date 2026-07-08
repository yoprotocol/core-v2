// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Integration_Test } from "../../../Integration.t.sol";

contract IsRouteAllowed_BridgeRouteRegistry_Integration_Concrete_Test is Integration_Test {
    address private constant ADAPTER = address(0xA11CE);
    address private constant TOKEN = address(0x1111);
    uint256 private constant DEST_ID = 8453;
    bytes32 private constant RECIPIENT = bytes32(uint256(0xBEEF));
    bytes32 private constant OUT = bytes32(uint256(0x0117));

    function test_GivenRouteNotSet() external view {
        assertFalse(
            routeRegistry.isRouteAllowed(users.vault, ADAPTER, TOKEN, DEST_ID, RECIPIENT, OUT), "unset route allowed"
        );
    }

    modifier givenRouteSetAllowed() {
        vm.prank(users.owner);
        routeRegistry.setRoute(users.vault, ADAPTER, TOKEN, DEST_ID, RECIPIENT, OUT, true);
        _;
    }

    function test_GivenRouteSetAllowed() external givenRouteSetAllowed {
        assertTrue(
            routeRegistry.isRouteAllowed(users.vault, ADAPTER, TOKEN, DEST_ID, RECIPIENT, OUT), "exact tuple denied"
        );
    }

    function test_GivenADifferentAdapter() external givenRouteSetAllowed {
        assertFalse(
            routeRegistry.isRouteAllowed(users.vault, address(0xDEAD), TOKEN, DEST_ID, RECIPIENT, OUT),
            "different adapter allowed"
        );
    }

    function test_GivenADifferentDestinationId() external givenRouteSetAllowed {
        assertFalse(
            routeRegistry.isRouteAllowed(users.vault, ADAPTER, TOKEN, DEST_ID + 1, RECIPIENT, OUT),
            "different destinationId allowed"
        );
    }

    function test_GivenADifferentRecipient() external givenRouteSetAllowed {
        assertFalse(
            routeRegistry.isRouteAllowed(users.vault, ADAPTER, TOKEN, DEST_ID, bytes32(uint256(0xCAFE)), OUT),
            "different recipient allowed"
        );
    }

    function test_GivenADifferentOutputToken() external givenRouteSetAllowed {
        assertFalse(
            routeRegistry.isRouteAllowed(users.vault, ADAPTER, TOKEN, DEST_ID, RECIPIENT, bytes32(uint256(0xF00D))),
            "different outputToken allowed"
        );
    }
}
