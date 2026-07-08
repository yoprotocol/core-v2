// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoAcrossAdapter } from "src/adapters/across/YoAcrossAdapter.sol";
import { IAcrossSpokePool } from "src/interfaces/external/IAcrossSpokePool.sol";
import { IYoAcrossAdapter } from "src/interfaces/IYoAcrossAdapter.sol";
import { IYoBridgeRouteRegistry } from "src/interfaces/IYoBridgeRouteRegistry.sol";
import { YoBridgeRouteRegistry } from "src/registries/YoBridgeRouteRegistry.sol";

import { Fork_Test } from "../Fork_Test.t.sol";

/// @notice End-to-end: real YoVault → YoAcrossAdapter → real Across `SpokePool` on Ethereum mainnet.
///         Bridges USDC to the same recipient on Base and asserts the origin-chain deposit pulled the
///         funds and left the adapter clean.
contract AcrossForkTest is Fork_Test {
    uint256 internal constant MAINNET_BLOCK = 0; // latest

    IAcrossSpokePool internal constant SPOKE_POOL = IAcrossSpokePool(0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5);
    IERC20 internal constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant BRIDGE_AMOUNT = 10_000e6;

    YoBridgeRouteRegistry internal routeRegistry;
    YoAcrossAdapter internal adapter;
    bytes32 internal recipient;

    function setUp() public {
        _maybeSkip(_forkIfAvailable("MAINNET_RPC_URL", MAINNET_BLOCK), "MAINNET_RPC_URL");

        _deployStack(USDC, "Yo Across Vault", "yoAX");

        vm.prank(users.owner);
        routeRegistry = new YoBridgeRouteRegistry(users.owner);
        adapter = new YoAcrossAdapter(SPOKE_POOL, IYoBridgeRouteRegistry(address(routeRegistry)), 50, yoRegistry);

        vm.label(address(adapter), "YoAcrossAdapter");
        vm.label(address(SPOKE_POOL), "AcrossSpokePool");
        vm.label(address(USDC), "USDC");

        recipient = bytes32(uint256(uint160(address(yoVault))));

        vm.prank(users.owner);
        routeRegistry.setRoute(
            address(yoVault),
            address(adapter),
            address(USDC),
            BASE_CHAIN_ID,
            recipient,
            bytes32(uint256(uint160(USDC_BASE))),
            true
        );

        deal(address(USDC), address(yoVault), BRIDGE_AMOUNT);
        _vaultApprove(USDC, address(adapter), type(uint256).max);
    }

    function test_Fork_Across_Deposit() external {
        uint256 vaultBefore = USDC.balanceOf(address(yoVault));

        IYoAcrossAdapter.DepositParams memory p = IYoAcrossAdapter.DepositParams({
            recipient: recipient,
            inputToken: address(USDC),
            outputToken: bytes32(uint256(uint160(USDC_BASE))),
            inputAmount: BRIDGE_AMOUNT,
            outputAmount: BRIDGE_AMOUNT - 10e6,
            destinationChainId: BASE_CHAIN_ID,
            exclusiveRelayer: bytes32(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 4 hours),
            exclusivityDeadline: 0,
            message: ""
        });

        bytes memory call = abi.encodeCall(YoAcrossAdapter.deposit, (p));
        uint256 bridged = abi.decode(_opManage(address(adapter), call), (uint256));

        assertEq(bridged, BRIDGE_AMOUNT, "return");
        assertEq(USDC.balanceOf(address(yoVault)), vaultBefore - BRIDGE_AMOUNT, "vault not debited");
        // Adapter retains nothing and leaks no allowance.
        assertEq(USDC.balanceOf(address(adapter)), 0, "adapter leaked USDC");
        assertEq(USDC.allowance(address(adapter), address(SPOKE_POOL)), 0, "adapter leaked allowance");
    }

    function test_Fork_Across_RevertWhen_RouteNotAllowed() external {
        IYoAcrossAdapter.DepositParams memory p = IYoAcrossAdapter.DepositParams({
            recipient: bytes32(uint256(0xDEAD)),
            inputToken: address(USDC),
            outputToken: bytes32(uint256(uint160(USDC_BASE))),
            inputAmount: BRIDGE_AMOUNT,
            outputAmount: BRIDGE_AMOUNT - 10e6,
            destinationChainId: BASE_CHAIN_ID,
            exclusiveRelayer: bytes32(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 4 hours),
            exclusivityDeadline: 0,
            message: ""
        });

        bytes memory call = abi.encodeCall(YoAcrossAdapter.deposit, (p));
        authority.setAllowed(users.operator, address(adapter), YoAcrossAdapter.deposit.selector, true);
        vm.prank(users.operator);
        vm.expectRevert();
        yoVault.manage(address(adapter), call, 0);
    }
}
