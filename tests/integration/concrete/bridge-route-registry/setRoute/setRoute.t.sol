// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IYoBridgeRouteRegistry } from "src/interfaces/IYoBridgeRouteRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract SetRoute_BridgeRouteRegistry_Integration_Concrete_Test is Integration_Test {
    address private constant ADAPTER = address(0xA11CE);
    address private constant TOKEN = address(0x1111);
    uint256 private constant DEST_ID = 8453;
    bytes32 private constant RECIPIENT = bytes32(uint256(0xBEEF));

    function test_RevertWhen_CallerNotOwner() external {
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.eve));
        routeRegistry.setRoute(users.vault, ADAPTER, TOKEN, DEST_ID, RECIPIENT, true);
    }

    function test_WhenVaultZero() external whenCallerOwner {
        vm.expectRevert(IYoBridgeRouteRegistry.ZeroAddress.selector);
        routeRegistry.setRoute(address(0), ADAPTER, TOKEN, DEST_ID, RECIPIENT, true);
    }

    function test_WhenAdapterZero() external whenCallerOwner {
        vm.expectRevert(IYoBridgeRouteRegistry.ZeroAddress.selector);
        routeRegistry.setRoute(users.vault, address(0), TOKEN, DEST_ID, RECIPIENT, true);
    }

    function test_WhenTokenZero() external whenCallerOwner {
        vm.expectRevert(IYoBridgeRouteRegistry.ZeroAddress.selector);
        routeRegistry.setRoute(users.vault, ADAPTER, address(0), DEST_ID, RECIPIENT, true);
    }

    modifier whenAllAddressesValid() {
        _;
    }

    function test_GivenAllowedTrue() external whenCallerOwner whenAllAddressesValid {
        vm.expectEmit(true, true, true, true, address(routeRegistry));
        emit IYoBridgeRouteRegistry.RouteSet(users.vault, ADAPTER, TOKEN, DEST_ID, RECIPIENT, true);
        routeRegistry.setRoute(users.vault, ADAPTER, TOKEN, DEST_ID, RECIPIENT, true);

        assertTrue(routeRegistry.isRouteAllowed(users.vault, ADAPTER, TOKEN, DEST_ID, RECIPIENT), "route not allowed");
    }

    function test_GivenAllowedFalse() external whenCallerOwner whenAllAddressesValid {
        routeRegistry.setRoute(users.vault, ADAPTER, TOKEN, DEST_ID, RECIPIENT, true);

        vm.expectEmit(true, true, true, true, address(routeRegistry));
        emit IYoBridgeRouteRegistry.RouteSet(users.vault, ADAPTER, TOKEN, DEST_ID, RECIPIENT, false);
        routeRegistry.setRoute(users.vault, ADAPTER, TOKEN, DEST_ID, RECIPIENT, false);

        assertFalse(
            routeRegistry.isRouteAllowed(users.vault, ADAPTER, TOKEN, DEST_ID, RECIPIENT), "route still allowed"
        );
    }
}
