// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { IAuthority } from "src/interfaces/IAuthority.sol";
import { YoRegistry } from "src/YoRegistry.sol";

import { MockAuthority } from "../../../../mocks/MockAuthority.sol";
import { YoRegistryBase_Test } from "../YoRegistryBase.t.sol";

contract InitializeIntegrationConcreteTest is YoRegistryBase_Test {
    function test_WhenProxyInitialized_SetsOwnerAndAuthority() external {
        MockAuthority a = new MockAuthority();

        YoRegistry impl = new YoRegistry();
        bytes memory initData = abi.encodeCall(YoRegistry.initialize, (users.bob, IAuthority(address(a))));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        YoRegistry r = YoRegistry(payable(address(proxy)));

        assertEq(r.owner(), users.bob);
        assertEq(address(r.authority()), address(a));
    }

    function test_RevertWhen_InitializeCalledTwice() external {
        // The base already initialized the proxy. Calling again must revert.
        vm.expectRevert();
        registry.initialize(users.bob, IAuthority(address(0)));
    }

    function test_RevertWhen_InitializeCalledOnImplementation() external {
        YoRegistry impl = new YoRegistry();
        vm.expectRevert();
        impl.initialize(users.owner, IAuthority(address(0)));
    }
}
