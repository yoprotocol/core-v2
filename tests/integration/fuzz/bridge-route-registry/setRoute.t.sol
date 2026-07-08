// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoBridgeRouteRegistry } from "src/interfaces/IYoBridgeRouteRegistry.sol";

import { Integration_Test } from "../../Integration.t.sol";

contract SetRoute_BridgeRouteRegistry_Integration_Fuzz_Test is Integration_Test {
    function test_RevertWhen_RenounceOwnership() external {
        vm.prank(users.owner);
        vm.expectRevert(IYoBridgeRouteRegistry.RenounceDisabled.selector);
        routeRegistry.renounceOwnership();
    }

    function testFuzz_SetRoute_RoundTrips(
        address vault,
        address adapter,
        address token,
        uint256 destinationId,
        bytes32 recipient,
        bytes32 outputToken
    )
        external
    {
        vm.assume(vault != address(0) && adapter != address(0) && token != address(0));

        vm.prank(users.owner);
        routeRegistry.setRoute(vault, adapter, token, destinationId, recipient, outputToken, true);
        assertTrue(
            routeRegistry.isRouteAllowed(vault, adapter, token, destinationId, recipient, outputToken), "not allowed"
        );

        vm.prank(users.owner);
        routeRegistry.setRoute(vault, adapter, token, destinationId, recipient, outputToken, false);
        assertFalse(
            routeRegistry.isRouteAllowed(vault, adapter, token, destinationId, recipient, outputToken), "still allowed"
        );
    }

    function testFuzz_SetRoute_IsolatedByKey(
        address adapter,
        uint256 destinationId,
        bytes32 recipient,
        bytes32 outputToken
    )
        external
    {
        vm.assume(adapter != address(0) && adapter != address(0xBEEF));
        vm.assume(destinationId != 1);
        vm.assume(outputToken != bytes32(uint256(0xF00D)));

        vm.prank(users.owner);
        routeRegistry.setRoute(users.vault, adapter, address(usdc), destinationId, recipient, outputToken, true);

        // A different adapter, destinationId, or outputToken is not implicitly allowed.
        assertFalse(
            routeRegistry.isRouteAllowed(
                users.vault, address(0xBEEF), address(usdc), destinationId, recipient, outputToken
            ),
            "adapter leak"
        );
        assertFalse(
            routeRegistry.isRouteAllowed(users.vault, adapter, address(usdc), 1, recipient, outputToken),
            "destinationId leak"
        );
        assertFalse(
            routeRegistry.isRouteAllowed(
                users.vault, adapter, address(usdc), destinationId, recipient, bytes32(uint256(0xF00D))
            ),
            "outputToken leak"
        );
    }
}
