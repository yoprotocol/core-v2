// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAuthority } from "src/interfaces/IAuthority.sol";
import { YoGateway } from "src/YoGateway.sol";
import { YoRegistry } from "src/YoRegistry.sol";

import { MockAuthority } from "../../../mocks/MockAuthority.sol";
import { MockYoVault } from "../../../mocks/MockYoVault.sol";
import { Integration_Test } from "../../Integration.t.sol";

/// @notice Shared base for `YoGateway` BTT tests. Uses a `MockERC4626` (standard, non-async) vault
///         as the target — gateway tests don't need the async-redeem branch.
abstract contract YoGatewayBase_Test is Integration_Test {
    YoRegistry internal registry;
    YoGateway internal gateway;
    MockAuthority internal authority;
    MockYoVault internal mockVault;

    function setUp() public virtual override {
        super.setUp();

        // Deploy YoRegistry behind ERC1967 proxy.
        YoRegistry registryImpl = new YoRegistry();
        bytes memory registryData = abi.encodeCall(YoRegistry.initialize, (users.owner, IAuthority(address(0))));
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryData);
        registry = YoRegistry(payable(address(registryProxy)));
        vm.label(address(registry), "YoRegistry");

        // Deploy YoGateway behind ERC1967 proxy.
        YoGateway gatewayImpl = new YoGateway();
        bytes memory gatewayData = abi.encodeCall(YoGateway.initialize, (address(registry)));
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), gatewayData);
        gateway = YoGateway(payable(address(gatewayProxy)));
        vm.label(address(gateway), "YoGateway");

        // Wire authority to registry so the owner can add vaults.
        authority = new MockAuthority();
        vm.prank(users.owner);
        registry.setAuthority(IAuthority(address(authority)));

        // Deploy a mock yield vault and allowlist it.
        mockVault = new MockYoVault(IERC20(address(usdc)), "Mock yUSDC", "myUSDC");
        vm.label(address(mockVault), "MockYoVault");
        vm.prank(users.owner);
        registry.addYoVault(address(mockVault));

        // Fund alice and bob and approve the gateway + vault for both asset & shares.
        usdc.mint(users.alice, 1_000_000e6);
        usdc.mint(users.bob, 1_000_000e6);

        vm.startPrank(users.alice);
        usdc.approve(address(gateway), type(uint256).max);
        usdc.approve(address(mockVault), type(uint256).max);
        mockVault.approve(address(gateway), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(users.bob);
        usdc.approve(address(gateway), type(uint256).max);
        usdc.approve(address(mockVault), type(uint256).max);
        mockVault.approve(address(gateway), type(uint256).max);
        vm.stopPrank();
    }
}
