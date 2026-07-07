// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Integration_Test } from "../../Integration.t.sol";

contract SetRoute_BridgeRouteRegistry_Integration_Fuzz_Test is Integration_Test {
    function testFuzz_SetRoute_RoundTrips(
        address vault,
        address adapter,
        address token,
        uint256 destinationId,
        bytes32 recipient
    )
        external
    {
        vm.assume(vault != address(0) && adapter != address(0) && token != address(0));

        vm.prank(users.owner);
        routeRegistry.setRoute(vault, adapter, token, destinationId, recipient, true);
        assertTrue(routeRegistry.isRouteAllowed(vault, adapter, token, destinationId, recipient), "not allowed");

        vm.prank(users.owner);
        routeRegistry.setRoute(vault, adapter, token, destinationId, recipient, false);
        assertFalse(routeRegistry.isRouteAllowed(vault, adapter, token, destinationId, recipient), "still allowed");
    }

    function testFuzz_SetRoute_IsolatedByKey(address adapter, uint256 destinationId, bytes32 recipient) external {
        vm.assume(adapter != address(0) && adapter != address(0xBEEF));
        vm.assume(destinationId != 1);

        vm.prank(users.owner);
        routeRegistry.setRoute(users.vault, adapter, address(usdc), destinationId, recipient, true);

        // A different adapter, destinationId, or recipient is not implicitly allowed.
        assertFalse(
            routeRegistry.isRouteAllowed(users.vault, address(0xBEEF), address(usdc), destinationId, recipient),
            "adapter leak"
        );
        assertFalse(
            routeRegistry.isRouteAllowed(users.vault, adapter, address(usdc), 1, recipient), "destinationId leak"
        );
    }
}
