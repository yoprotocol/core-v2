// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoCcipAdapter } from "src/adapters/ccip/YoCcipAdapter.sol";
import { CcipClient } from "src/interfaces/external/CcipClient.sol";
import { ICcipRouterClient } from "src/interfaces/external/ICcipRouterClient.sol";
import { IYoBridgeRouteRegistry } from "src/interfaces/IYoBridgeRouteRegistry.sol";
import { YoBridgeRouteRegistry } from "src/registries/YoBridgeRouteRegistry.sol";

import { Fork_Test } from "../Fork_Test.t.sol";

/// @notice End-to-end: real YoVault → YoCcipAdapter → real CCIP `Router` on Ethereum mainnet. Sends
///         USDC to the vault's address on Base, paying the fee in LINK, and asserts the source-side
///         transfer pulled the funds and left the adapter clean.
contract CcipForkTest is Fork_Test {
    uint256 internal constant MAINNET_BLOCK = 0; // latest

    ICcipRouterClient internal constant ROUTER = ICcipRouterClient(0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D);
    IERC20 internal constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 internal constant LINK = IERC20(0x514910771AF9Ca656af840dff83E8264EcF986CA);
    uint64 internal constant BASE_SELECTOR = 15_971_525_489_660_198_786;
    uint256 internal constant BRIDGE_AMOUNT = 100e6;

    YoBridgeRouteRegistry internal routeRegistry;
    YoCcipAdapter internal adapter;
    bytes32 internal recipient;

    function setUp() public {
        _maybeSkip(_forkIfAvailable("MAINNET_RPC_URL", MAINNET_BLOCK), "MAINNET_RPC_URL");

        _deployStack(USDC, "Yo CCIP Vault", "yoCP");

        vm.prank(users.owner);
        routeRegistry = new YoBridgeRouteRegistry(users.owner);
        adapter = new YoCcipAdapter(ROUTER, IYoBridgeRouteRegistry(address(routeRegistry)), yoRegistry);

        vm.label(address(adapter), "YoCcipAdapter");
        vm.label(address(ROUTER), "CcipRouter");
        vm.label(address(USDC), "USDC");
        vm.label(address(LINK), "LINK");

        recipient = bytes32(uint256(uint160(address(yoVault))));

        vm.prank(users.owner);
        routeRegistry.setRoute(address(yoVault), address(adapter), address(USDC), BASE_SELECTOR, recipient, true);

        deal(address(USDC), address(yoVault), BRIDGE_AMOUNT);
        deal(address(LINK), address(yoVault), 100e18);
        _vaultApprove(USDC, address(adapter), type(uint256).max);
        _vaultApprove(LINK, address(adapter), type(uint256).max);
    }

    function test_Fork_Ccip_Send() external {
        uint256 vaultUsdcBefore = USDC.balanceOf(address(yoVault));
        uint256 vaultLinkBefore = LINK.balanceOf(address(yoVault));

        bytes memory extraArgs =
            CcipClient._argsToBytes(CcipClient.GenericExtraArgsV2({ gasLimit: 0, allowOutOfOrderExecution: true }));
        bytes memory call = abi.encodeCall(
            YoCcipAdapter.send,
            (BASE_SELECTOR, recipient, address(USDC), BRIDGE_AMOUNT, address(LINK), type(uint256).max, extraArgs)
        );
        bytes32 messageId = abi.decode(_opManage(address(adapter), call), (bytes32));

        assertTrue(messageId != bytes32(0), "no messageId");
        assertEq(USDC.balanceOf(address(yoVault)), vaultUsdcBefore - BRIDGE_AMOUNT, "vault USDC not debited");
        assertLt(LINK.balanceOf(address(yoVault)), vaultLinkBefore, "LINK fee not paid");
        // Adapter retains nothing and leaks no allowance.
        assertEq(USDC.balanceOf(address(adapter)), 0, "adapter leaked USDC");
        assertEq(LINK.balanceOf(address(adapter)), 0, "adapter leaked LINK");
        assertEq(USDC.allowance(address(adapter), address(ROUTER)), 0, "adapter leaked USDC allowance");
        assertEq(LINK.allowance(address(adapter), address(ROUTER)), 0, "adapter leaked LINK allowance");
    }

    function test_Fork_Ccip_SendNativeFee() external {
        // Fund the vault with native so `manage` can forward the CCIP fee as value.
        vm.deal(address(yoVault), 1 ether);
        uint256 vaultUsdcBefore = USDC.balanceOf(address(yoVault));

        bytes memory extraArgs =
            CcipClient._argsToBytes(CcipClient.GenericExtraArgsV2({ gasLimit: 0, allowOutOfOrderExecution: true }));
        bytes memory call = abi.encodeCall(
            YoCcipAdapter.send,
            (BASE_SELECTOR, recipient, address(USDC), BRIDGE_AMOUNT, address(0), type(uint256).max, extraArgs)
        );

        // Forward a native value comfortably above the quoted fee; the excess stays rescuable.
        authority.setAllowed(users.operator, address(adapter), YoCcipAdapter.send.selector, true);
        vm.prank(users.operator);
        bytes32 messageId = abi.decode(yoVault.manage(address(adapter), call, 0.1 ether), (bytes32));

        assertTrue(messageId != bytes32(0), "no messageId");
        assertEq(USDC.balanceOf(address(yoVault)), vaultUsdcBefore - BRIDGE_AMOUNT, "vault USDC not debited");
        assertEq(USDC.balanceOf(address(adapter)), 0, "adapter leaked USDC");
        assertEq(USDC.allowance(address(adapter), address(ROUTER)), 0, "adapter leaked USDC allowance");
    }

    function test_Fork_Ccip_RevertWhen_RouteNotAllowed() external {
        bytes32 badRecipient = bytes32(uint256(0xDEAD));
        bytes memory extraArgs =
            CcipClient._argsToBytes(CcipClient.GenericExtraArgsV2({ gasLimit: 0, allowOutOfOrderExecution: true }));
        bytes memory call = abi.encodeCall(
            YoCcipAdapter.send,
            (BASE_SELECTOR, badRecipient, address(USDC), BRIDGE_AMOUNT, address(LINK), type(uint256).max, extraArgs)
        );
        authority.setAllowed(users.operator, address(adapter), YoCcipAdapter.send.selector, true);
        vm.prank(users.operator);
        vm.expectRevert();
        yoVault.manage(address(adapter), call, 0);
    }
}
