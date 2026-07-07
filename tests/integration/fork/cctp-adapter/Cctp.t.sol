// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoCctpAdapter } from "src/adapters/cctp/YoCctpAdapter.sol";
import { ITokenMessengerV2 } from "src/interfaces/external/ITokenMessengerV2.sol";
import { IYoBridgeRouteRegistry } from "src/interfaces/IYoBridgeRouteRegistry.sol";
import { YoBridgeRouteRegistry } from "src/registries/YoBridgeRouteRegistry.sol";

import { Fork_Test } from "../Fork_Test.t.sol";

/// @notice End-to-end: real YoVault → YoCctpAdapter → real CCTP V2 `TokenMessengerV2` on Ethereum
///         mainnet. Burns USDC for minting on Base (domain 6) and asserts the burn pulled the funds
///         and left the adapter clean.
contract CctpForkTest is Fork_Test {
    uint256 internal constant MAINNET_BLOCK = 0; // latest

    ITokenMessengerV2 internal constant TOKEN_MESSENGER = ITokenMessengerV2(0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d);
    IERC20 internal constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    uint32 internal constant BASE_DOMAIN = 6;
    uint32 internal constant STANDARD_FINALITY = 2000;
    uint256 internal constant BRIDGE_AMOUNT = 10_000e6;

    YoBridgeRouteRegistry internal routeRegistry;
    YoCctpAdapter internal adapter;
    bytes32 internal recipient;

    function setUp() public {
        _maybeSkip(_forkIfAvailable("MAINNET_RPC_URL", MAINNET_BLOCK), "MAINNET_RPC_URL");

        _deployStack(USDC, "Yo CCTP Vault", "yoCC");

        vm.prank(users.owner);
        routeRegistry = new YoBridgeRouteRegistry(users.owner);
        adapter = new YoCctpAdapter(TOKEN_MESSENGER, USDC, IYoBridgeRouteRegistry(address(routeRegistry)), yoRegistry);

        vm.label(address(adapter), "YoCctpAdapter");
        vm.label(address(TOKEN_MESSENGER), "TokenMessengerV2");
        vm.label(address(USDC), "USDC");

        recipient = bytes32(uint256(uint160(address(yoVault))));

        vm.prank(users.owner);
        routeRegistry.setRoute(address(yoVault), address(adapter), address(USDC), BASE_DOMAIN, recipient, true);

        deal(address(USDC), address(yoVault), BRIDGE_AMOUNT);
        _vaultApprove(USDC, address(adapter), type(uint256).max);
    }

    function test_Fork_Cctp_DepositForBurn() external {
        uint256 vaultBefore = USDC.balanceOf(address(yoVault));
        uint256 supplyBefore = USDC.totalSupply();

        bytes memory call = abi.encodeCall(
            YoCctpAdapter.depositForBurn, (BRIDGE_AMOUNT, BASE_DOMAIN, recipient, bytes32(0), 0, STANDARD_FINALITY)
        );
        uint256 burned = abi.decode(_opManage(address(adapter), call), (uint256));

        assertEq(burned, BRIDGE_AMOUNT, "return");
        assertEq(USDC.balanceOf(address(yoVault)), vaultBefore - BRIDGE_AMOUNT, "vault not debited");
        // CCTP burns the USDC on the source chain — total supply drops by the bridged amount.
        assertEq(USDC.totalSupply(), supplyBefore - BRIDGE_AMOUNT, "USDC not burned");
        // Adapter retains nothing and leaks no allowance.
        assertEq(USDC.balanceOf(address(adapter)), 0, "adapter leaked USDC");
        assertEq(USDC.allowance(address(adapter), address(TOKEN_MESSENGER)), 0, "adapter leaked allowance");
    }

    function test_Fork_Cctp_RevertWhen_RouteNotAllowed() external {
        bytes32 badRecipient = bytes32(uint256(0xDEAD));
        bytes memory call = abi.encodeCall(
            YoCctpAdapter.depositForBurn, (BRIDGE_AMOUNT, BASE_DOMAIN, badRecipient, bytes32(0), 0, STANDARD_FINALITY)
        );
        authority.setAllowed(users.operator, address(adapter), YoCctpAdapter.depositForBurn.selector, true);
        vm.prank(users.operator);
        vm.expectRevert();
        yoVault.manage(address(adapter), call, 0);
    }
}
