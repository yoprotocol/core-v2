// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { YoCcipAdapter } from "src/adapters/ccip/YoCcipAdapter.sol";
import { ICcipRouterClient } from "src/interfaces/external/ICcipRouterClient.sol";
import { IYoBridgeRouteRegistry } from "src/interfaces/IYoBridgeRouteRegistry.sol";
import { YoBridgeRouteRegistry } from "src/registries/YoBridgeRouteRegistry.sol";

import { MockCcipRouter } from "../../../mocks/MockCcipRouter.sol";
import { MockERC20 } from "../../../mocks/MockERC20.sol";
import { Fork_Test } from "../../fork/Fork_Test.t.sol";

/// @notice Deterministic end-to-end test (no fork) of the CCIP native-ETH fee path through the real
///         `YoVault.manage` value-forwarding: the vault holds ETH, the operator calls `manage` with a
///         native `value`, `YoVault` forwards it into the adapter's payable `send`, and the adapter
///         forwards it as `msg.value` to `ccipSend`. Uses the mock router so the ETH fee receipt and
///         the vault's ETH spend can be asserted exactly. Reuses {Fork_Test._deployStack} to get a
///         real `YoVault` + authority stack locally.
contract CcipNativeFeeViaManageTest is Fork_Test {
    uint64 internal constant DEST_SELECTOR = 15_971_525_489_660_198_786; // Base
    uint256 internal constant AMOUNT = 1000e6;
    uint256 internal constant FEE = 0.02 ether;

    MockERC20 internal token;
    MockCcipRouter internal router;
    YoBridgeRouteRegistry internal routeReg;
    YoCcipAdapter internal adapter;
    bytes32 internal recipient;

    function setUp() public {
        token = new MockERC20("USD Coin", "USDC", 6);
        _deployStack(IERC20(address(token)), "Yo CCIP Vault", "yoCP");

        router = new MockCcipRouter();
        router.setFee(FEE);

        vm.prank(users.owner);
        routeReg = new YoBridgeRouteRegistry(users.owner);
        adapter = new YoCcipAdapter(
            ICcipRouterClient(address(router)), IYoBridgeRouteRegistry(address(routeReg)), yoRegistry
        );

        recipient = bytes32(uint256(uint160(address(yoVault))));
        vm.prank(users.owner);
        routeReg.setRoute(
            address(yoVault), address(adapter), address(token), DEST_SELECTOR, recipient, bytes32(0), true
        );

        token.mint(address(yoVault), AMOUNT);
        _vaultApprove(IERC20(address(token)), address(adapter), type(uint256).max);

        // The vault holds the ETH that funds the CCIP fee.
        vm.deal(address(yoVault), 1 ether);
    }

    function test_Ccip_NativeFee_ViaManage() external {
        uint256 vaultEthBefore = address(yoVault).balance;

        bytes memory call = abi.encodeCall(
            YoCcipAdapter.send, (DEST_SELECTOR, recipient, address(token), AMOUNT, address(0), FEE, "")
        );

        // Operator drives the vault to bridge, forwarding the fee as native `value` from the vault.
        authority.setAllowed(users.operator, address(adapter), YoCcipAdapter.send.selector, true);
        vm.prank(users.operator);
        bytes32 messageId = abi.decode(yoVault.manage(address(adapter), call, FEE), (bytes32));

        assertEq(messageId, router.nextMessageId(), "messageId");
        // The vault's own ETH funded the fee, and the router received it as native value.
        assertEq(address(yoVault).balance, vaultEthBefore - FEE, "vault ETH not spent");
        assertEq(address(router).balance, FEE, "router did not receive ETH fee");
        // Token leg pulled and forwarded; adapter left clean.
        assertEq(token.balanceOf(address(router)), AMOUNT, "router token leg");
        assertEq(token.balanceOf(address(adapter)), 0, "adapter leaked token");
        assertEq(address(adapter).balance, 0, "adapter retained ETH");
        assertEq(token.allowance(address(adapter), address(router)), 0, "adapter leaked allowance");
    }

    function test_Ccip_NativeFee_ViaManage_OverpayRescuable() external {
        // Overpaying the fee via `manage` leaves the excess in the adapter (it forwards exactly the
        // quoted fee); the vault reclaims it via `rescueETH` since YO vaults are payable ({Compatible}).
        uint256 overpay = FEE + 0.01 ether;
        bytes memory call =
            abi.encodeCall(YoCcipAdapter.send, (DEST_SELECTOR, recipient, address(token), AMOUNT, address(0), FEE, ""));
        authority.setAllowed(users.operator, address(adapter), YoCcipAdapter.send.selector, true);
        vm.prank(users.operator);
        yoVault.manage(address(adapter), call, overpay);

        assertEq(address(router).balance, FEE, "router got exactly the fee");
        assertEq(address(adapter).balance, overpay - FEE, "excess should stay in the adapter");

        // The vault reclaims the stranded excess via rescueETH (paid to msg.sender = the vault).
        uint256 vaultEthBefore = address(yoVault).balance;
        authority.setAllowed(users.operator, address(adapter), YoAdapterBase.rescueETH.selector, true);
        vm.prank(users.operator);
        yoVault.manage(address(adapter), abi.encodeCall(YoAdapterBase.rescueETH, ()), 0);

        assertEq(address(yoVault).balance, vaultEthBefore + (overpay - FEE), "excess not rescued to vault");
        assertEq(address(adapter).balance, 0, "adapter still holds ETH");
    }
}
