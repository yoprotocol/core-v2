// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAuthority } from "src/interfaces/IAuthority.sol";
import { YoRegistry } from "src/YoRegistry.sol";

import { MockAuthority } from "../../../mocks/MockAuthority.sol";
import { MockERC4626 } from "../../../mocks/MockERC4626.sol";
import { Integration_Test } from "../../Integration.t.sol";

/// @notice Shared base for `YoRegistry` BTT tests. Deploys the registry behind an ERC-1967 proxy,
///         wires a `MockAuthority`, and grants the operator the per-method selectors.
abstract contract YoRegistryBase_Test is Integration_Test {
    YoRegistry internal registry;
    MockAuthority internal authority;

    function _makeMockVault() internal returns (address) {
        return address(new MockERC4626(IERC20(address(usdc)), "Mock Vault", "mV"));
    }

    function setUp() public virtual override {
        super.setUp();

        // Deploy implementation + proxy with atomic init.
        YoRegistry impl = new YoRegistry();
        bytes memory initData = abi.encodeCall(YoRegistry.initialize, (users.owner, IAuthority(address(0))));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        registry = YoRegistry(payable(address(proxy)));
        vm.label(address(impl), "YoRegistryImpl");
        vm.label(address(registry), "YoRegistry");

        // Wire authority.
        authority = new MockAuthority();
        vm.label(address(authority), "MockAuthority");
        vm.prank(users.owner);
        registry.setAuthority(IAuthority(address(authority)));

        // Grant the operator the standard hot-key selector set.
        authority.setAllowed(users.operator, address(registry), YoRegistry.addYoVault.selector, true);
        authority.setAllowed(users.operator, address(registry), YoRegistry.removeYoVault.selector, true);
    }
}
