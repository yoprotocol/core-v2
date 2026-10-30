// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoCctpxAdapter } from "src/adapters/cctpx/YoCctpxAdapter.sol";
import { ICrossChainTokenService } from "src/interfaces/external/ICrossChainTokenService.sol";
import { IYoBridgeRouteRegistry } from "src/interfaces/IYoBridgeRouteRegistry.sol";
import { IYoCctpxAdapter } from "src/interfaces/IYoCctpxAdapter.sol";
import { YoBridgeRouteRegistry } from "src/registries/YoBridgeRouteRegistry.sol";

import {
    MockCctpxFeeManager,
    MockCctpxTokenManager,
    MockCrossChainTokenService
} from "../../../mocks/MockCrossChainTokenService.sol";
import { MockERC20 } from "../../../mocks/MockERC20.sol";
import { Fork_Test } from "../../fork/Fork_Test.t.sol";

/// @notice Deterministic end-to-end test (no fork) of the CCTPx native-ETH fee path through the real
///         `YoVault.manage` value-forwarding: the vault holds ETH, the operator calls `manage` with a
///         native `value`, `YoVault` forwards it into the adapter's payable `crossChainTransfer`, and the
///         adapter forwards it as `msg.value` to the service. Uses the mock service so the fee receipt,
///         the vault's ETH spend, and the refund address can be asserted exactly. Reuses
///         {Fork_Test._deployStack} to get a real `YoVault` + authority stack locally.
contract CctpxNativeFeeViaManageTest is Fork_Test {
    bytes32 internal constant TOKEN_ID = keccak256("EURC");
    uint32 internal constant DEST_DOMAIN = 0; // Ethereum
    uint32 internal constant STANDARD_FINALITY = 2000;
    uint256 internal constant AMOUNT = 1000e6;
    uint256 internal constant FEE = 0.0001 ether;
    uint256 internal constant MAX_NATIVE_FEE = 0.02 ether;

    MockERC20 internal token;
    MockCctpxFeeManager internal feeManager;
    MockCrossChainTokenService internal service;
    MockCctpxTokenManager internal tokenManager;
    YoBridgeRouteRegistry internal routeReg;
    YoCctpxAdapter internal adapter;
    address internal recipient;
    bytes internal quote;

    function setUp() public {
        token = new MockERC20("EURC", "EURC", 6);
        _deployStack(IERC20(address(token)), "Yo CCTPx Vault", "yoCX");

        feeManager = new MockCctpxFeeManager();
        service = new MockCrossChainTokenService(feeManager);
        tokenManager = service.register(TOKEN_ID, IERC20(address(token)));

        vm.prank(users.owner);
        routeReg = new YoBridgeRouteRegistry(users.owner);
        adapter = new YoCctpxAdapter(
            ICrossChainTokenService(address(service)),
            IERC20(address(token)),
            TOKEN_ID,
            IYoBridgeRouteRegistry(address(routeReg)),
            MAX_NATIVE_FEE,
            yoRegistry
        );

        // The destination vault has the same address on the other chain.
        recipient = address(yoVault);
        vm.prank(users.owner);
        routeReg.setRoute(
            address(yoVault),
            address(adapter),
            address(token),
            DEST_DOMAIN,
            bytes32(uint256(uint160(recipient))),
            bytes32(0),
            true
        );

        token.mint(address(yoVault), AMOUNT);
        _vaultApprove(IERC20(address(token)), address(adapter), AMOUNT);
        authority.setAllowed(users.operator, address(adapter), YoCctpxAdapter.crossChainTransfer.selector, true);
        quote = abi.encode(FEE);

        // The vault holds the ETH that funds the CCTPx fee.
        vm.deal(address(yoVault), 1 ether);
    }

    function test_Cctpx_NativeFee_ViaManage() external {
        uint256 vaultEthBefore = address(yoVault).balance;

        // Operator drives the vault to bridge, forwarding exactly the quoted fee as native `value`.
        vm.prank(users.operator);
        uint256 sent = abi.decode(yoVault.manage(address(adapter), _call(), FEE), (uint256));

        assertEq(sent, AMOUNT, "return");
        // The vault's own ETH funded the fee, and the service paid all of it to the fee manager.
        assertEq(address(yoVault).balance, vaultEthBefore - FEE, "vault ETH not spent");
        assertEq(address(feeManager).balance, FEE, "fee manager did not receive ETH fee");
        assertEq(address(service).balance, 0, "service kept ETH");
        // The vault, not the operator, gets any fee refund.
        assertEq(service.last().refundAddress, address(yoVault), "refund address");
        // Token leg pulled through the token manager; adapter left clean.
        assertEq(token.balanceOf(address(yoVault)), 0, "vault token leg");
        assertEq(token.balanceOf(address(tokenManager)), AMOUNT, "token manager token leg");
        assertEq(token.balanceOf(address(adapter)), 0, "adapter leaked token");
        assertEq(address(adapter).balance, 0, "adapter retained ETH");
        assertEq(token.allowance(address(adapter), address(tokenManager)), 0, "adapter leaked allowance");
    }

    function test_Cctpx_NativeFee_ViaManage_RevertWhen_Overpaid() external {
        // Unlike CCIP, the service would keep the excess, so it is not rescuable from the adapter: reject it.
        vm.prank(users.operator);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.IncorrectNativeFee.selector, FEE + 1, FEE));
        yoVault.manage(address(adapter), _call(), FEE + 1);
    }

    function test_Cctpx_NativeFee_ViaManage_RevertWhen_Underpaid() external {
        // ETH that earlier callers left in the service would cover the fee: the vault would pay nothing.
        vm.deal(address(service), FEE);

        vm.prank(users.operator);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.IncorrectNativeFee.selector, 0, FEE));
        yoVault.manage(address(adapter), _call(), 0);
    }

    function _call() private view returns (bytes memory) {
        return
            abi.encodeCall(
                YoCctpxAdapter.crossChainTransfer, (AMOUNT, DEST_DOMAIN, recipient, STANDARD_FINALITY, quote)
            );
    }
}
