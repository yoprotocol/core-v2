// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoMayanAdapter } from "src/adapters/mayan/YoMayanAdapter.sol";
import { IMayanForwarder } from "src/interfaces/external/IMayanForwarder.sol";
import { IMayanSwift } from "src/interfaces/external/IMayanSwift.sol";
import { IYoBridgeRouteRegistry } from "src/interfaces/IYoBridgeRouteRegistry.sol";
import { YoBridgeRouteRegistry } from "src/registries/YoBridgeRouteRegistry.sol";

import { Fork_Test } from "../Fork_Test.t.sol";

/// @notice End-to-end: real YoVault → YoMayanAdapter → real Mayan Forwarder + Swift on Ethereum
///         mainnet. Creates a real Swift order for USDC (Base destination) and asserts the funds left
///         the vault and the adapter is clean. This also validates the on-chain `OrderParams` layout
///         used by the adapter's decode — a wrong layout would make the real Swift call revert.
contract MayanForkTest is Fork_Test {
    uint256 internal constant MAINNET_BLOCK = 0; // latest

    IMayanForwarder internal constant FORWARDER = IMayanForwarder(0x337685fdaB40D39bd02028545a4FfA7D287cC3E2);
    address internal constant SWIFT = 0xC38e4e6A15593f908255214653d3D947CA1c2338;
    IERC20 internal constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint16 internal constant BASE_WORMHOLE_CHAIN = 30;
    uint256 internal constant BRIDGE_AMOUNT = 10_000e6;

    YoBridgeRouteRegistry internal routeRegistry;
    YoMayanAdapter internal adapter;
    bytes32 internal recipient;

    function setUp() public {
        _maybeSkip(_forkIfAvailable("MAINNET_RPC_URL", MAINNET_BLOCK), "MAINNET_RPC_URL");

        _deployStack(USDC, "Yo Mayan Vault", "yoMY");

        vm.prank(users.owner);
        routeRegistry = new YoBridgeRouteRegistry(users.owner);
        adapter = new YoMayanAdapter(FORWARDER, SWIFT, IYoBridgeRouteRegistry(address(routeRegistry)), yoRegistry);

        vm.label(address(adapter), "YoMayanAdapter");
        vm.label(address(FORWARDER), "MayanForwarder");
        vm.label(SWIFT, "MayanSwift");
        vm.label(address(USDC), "USDC");

        recipient = bytes32(uint256(uint160(address(yoVault))));

        vm.prank(users.owner);
        routeRegistry.setRoute(address(yoVault), address(adapter), address(USDC), BASE_WORMHOLE_CHAIN, recipient, true);

        deal(address(USDC), address(yoVault), BRIDGE_AMOUNT);
        _vaultApprove(USDC, address(adapter), type(uint256).max);
    }

    function _orderData() internal view returns (bytes memory) {
        IMayanSwift.OrderParams memory o = IMayanSwift.OrderParams({
            trader: bytes32(uint256(uint160(address(yoVault)))),
            tokenOut: bytes32(uint256(uint160(USDC_BASE))),
            minAmountOut: uint64(BRIDGE_AMOUNT - 100e6),
            gasDrop: 0,
            cancelFee: 0,
            refundFee: 0,
            deadline: uint64(block.timestamp + 1 hours),
            destAddr: recipient,
            destChainId: BASE_WORMHOLE_CHAIN,
            referrerAddr: bytes32(0),
            referrerBps: 0,
            auctionMode: 2,
            random: bytes32(uint256(1))
        });
        return abi.encodeWithSelector(IMayanSwift.createOrderWithToken.selector, address(USDC), BRIDGE_AMOUNT, o);
    }

    function test_Fork_Mayan_ForwardERC20() external {
        uint256 vaultBefore = USDC.balanceOf(address(yoVault));

        bytes memory call = abi.encodeCall(YoMayanAdapter.forwardERC20, (address(USDC), BRIDGE_AMOUNT, _orderData()));
        uint256 forwarded = abi.decode(_opManage(address(adapter), call), (uint256));

        assertEq(forwarded, BRIDGE_AMOUNT, "return");
        assertEq(USDC.balanceOf(address(yoVault)), vaultBefore - BRIDGE_AMOUNT, "vault not debited");
        // Adapter retains nothing and leaks no allowance.
        assertEq(USDC.balanceOf(address(adapter)), 0, "adapter leaked USDC");
        assertEq(USDC.allowance(address(adapter), address(FORWARDER)), 0, "adapter leaked allowance");
    }

    function test_Fork_Mayan_RevertWhen_RouteNotAllowed() external {
        IMayanSwift.OrderParams memory o = IMayanSwift.OrderParams({
            trader: bytes32(uint256(uint160(address(yoVault)))),
            tokenOut: bytes32(uint256(uint160(USDC_BASE))),
            minAmountOut: uint64(BRIDGE_AMOUNT - 100e6),
            gasDrop: 0,
            cancelFee: 0,
            refundFee: 0,
            deadline: uint64(block.timestamp + 1 hours),
            destAddr: bytes32(uint256(0xDEAD)),
            destChainId: BASE_WORMHOLE_CHAIN,
            referrerAddr: bytes32(0),
            referrerBps: 0,
            auctionMode: 2,
            random: bytes32(uint256(1))
        });
        bytes memory data =
            abi.encodeWithSelector(IMayanSwift.createOrderWithToken.selector, address(USDC), BRIDGE_AMOUNT, o);

        bytes memory call = abi.encodeCall(YoMayanAdapter.forwardERC20, (address(USDC), BRIDGE_AMOUNT, data));
        authority.setAllowed(users.operator, address(adapter), YoMayanAdapter.forwardERC20.selector, true);
        vm.prank(users.operator);
        vm.expectRevert();
        yoVault.manage(address(adapter), call, 0);
    }
}
