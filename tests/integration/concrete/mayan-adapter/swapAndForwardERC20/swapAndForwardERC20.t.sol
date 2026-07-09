// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IMayanSwift } from "src/interfaces/external/IMayanSwift.sol";
import { IYoMayanAdapter } from "src/interfaces/IYoMayanAdapter.sol";

import { Integration_Test } from "../../../Integration.t.sol";
import { MayanOrders } from "../../../../utils/MayanOrders.sol";

contract SwapAndForwardERC20_MayanAdapter_Integration_Concrete_Test is Integration_Test {
    uint16 private destChain;
    bytes32 private recipient;
    uint256 private amount;
    address private swapProtocol;

    function setUp() public override {
        Integration_Test.setUp();
        destChain = defaults.MAYAN_DEST_WORMHOLE_CHAIN();
        recipient = defaults.BRIDGE_RECIPIENT();
        amount = defaults.BRIDGE_AMOUNT();
        swapProtocol = makeAddr("SwapProtocol");
    }

    /// @dev Swift order whose declared input token is `orderTokenIn` (must equal the middle token).
    ///      `tokenOut` is usdc — a same-asset bridge (tokenIn usdc == tokenOut usdc) — and
    ///      `minAmountOut` is the full input, clearing the swap-path delivery floor. The order amount
    ///      is a placeholder; the Forwarder rewrites it with the swap output.
    function _order(address orderTokenIn, bytes32 trader, bytes32 destAddr) internal view returns (bytes memory) {
        return MayanOrders.encode(
            orderTokenIn, uint256(0), MayanOrders.order(trader, destAddr, destChain, address(usdc), uint64(amount))
        );
    }

    function _vaultTrader() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(users.vault))));
    }

    function _params(
        address middleToken,
        uint256 minMiddleAmount,
        bytes memory mayanData
    )
        internal
        view
        returns (IYoMayanAdapter.SwapForwardParams memory)
    {
        return IYoMayanAdapter.SwapForwardParams({
            tokenIn: address(usdc),
            amountIn: amount,
            swapProtocol: swapProtocol,
            swapData: hex"",
            middleToken: middleToken,
            minMiddleAmount: minMiddleAmount,
            mayanData: mayanData
        });
    }

    /// @dev Oracle floor for `amount` of usdc→usdt at the configured max slippage (1:1 quote).
    function _floor() internal view returns (uint256) {
        return mockOracle.getQuote(address(usdc), address(usdt), amount)
            * (defaults.BPS_DENOMINATOR() - defaults.MAX_SLIPPAGE_BPS()) / defaults.BPS_DENOMINATOR();
    }

    function test_WhenAmountInZero() external {
        IYoMayanAdapter.SwapForwardParams memory p =
            _params(address(usdt), 995e6, _order(address(usdt), _vaultTrader(), recipient));
        p.amountIn = 0;
        vm.prank(users.vault);
        vm.expectRevert(IYoMayanAdapter.InvalidAmount.selector);
        mayanAdapter.swapAndForwardERC20(p);
    }

    modifier whenAmountInNonZero() {
        _;
    }

    function test_WhenOrderTokenNotMiddleToken() external whenAmountInNonZero {
        // Order declares usdc but middleToken is usdt.
        IYoMayanAdapter.SwapForwardParams memory p =
            _params(address(usdt), 995e6, _order(address(usdc), _vaultTrader(), recipient));
        vm.prank(users.vault);
        vm.expectRevert(IYoMayanAdapter.ProtocolDataMismatch.selector);
        mayanAdapter.swapAndForwardERC20(p);
    }

    function test_WhenTraderNotVault() external whenAmountInNonZero {
        bytes32 badTrader = bytes32(uint256(uint160(address(users.eve))));
        IYoMayanAdapter.SwapForwardParams memory p =
            _params(address(usdt), 995e6, _order(address(usdt), badTrader, recipient));
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMayanAdapter.TraderNotVault.selector, badTrader));
        mayanAdapter.swapAndForwardERC20(p);
    }

    function test_WhenRouteNotAllowed() external whenAmountInNonZero {
        bytes32 badDest = bytes32(uint256(0xDEAD));
        IYoMayanAdapter.SwapForwardParams memory p =
            _params(address(usdt), 995e6, _order(address(usdt), _vaultTrader(), badDest));
        vm.prank(users.vault);
        vm.expectRevert(
            abi.encodeWithSelector(IYoMayanAdapter.RouteNotAllowed.selector, address(usdc), destChain, badDest)
        );
        mayanAdapter.swapAndForwardERC20(p);
    }

    function test_WhenSwapPairDisallowed() external whenAmountInNonZero {
        // (usdc, weth) is not an allowlisted swap pair — a stand-in for an operator-chosen fake token.
        IYoMayanAdapter.SwapForwardParams memory p =
            _params(address(weth), 995e6, _order(address(weth), _vaultTrader(), recipient));
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMayanAdapter.PairNotAllowed.selector, address(usdc), address(weth)));
        mayanAdapter.swapAndForwardERC20(p);
    }

    function test_WhenMinMiddleAmountBelowOracleFloor() external whenAmountInNonZero {
        uint256 floor = _floor();
        IYoMayanAdapter.SwapForwardParams memory p =
            _params(address(usdt), 1, _order(address(usdt), _vaultTrader(), recipient));
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMayanAdapter.SlippageTooLow.selector, uint256(1), floor));
        mayanAdapter.swapAndForwardERC20(p);
    }

    function test_WhenMinAmountOutBelowBridgeFloor() external whenAmountInNonZero {
        // Delivery floor is keyed on the vault's input (usdc, 6-dp) at the wider bridge slippage.
        uint256 deliveryFloor =
            (amount * (defaults.BPS_DENOMINATOR() - defaults.MAX_BRIDGE_SLIPPAGE_BPS())) / defaults.BPS_DENOMINATOR();

        IMayanSwift.OrderParams memory o =
            MayanOrders.order(_vaultTrader(), recipient, destChain, address(usdc), uint64(deliveryFloor - 1));
        bytes memory data = MayanOrders.encode(address(usdt), uint256(0), o);
        IYoMayanAdapter.SwapForwardParams memory p = _params(address(usdt), _floor(), data);

        vm.prank(users.vault);
        vm.expectRevert(
            abi.encodeWithSelector(IYoMayanAdapter.MinAmountOutTooLow.selector, deliveryFloor - 1, deliveryFloor)
        );
        mayanAdapter.swapAndForwardERC20(p);
    }

    function test_WhenValidAndWithinSlippage() external whenAmountInNonZero {
        uint256 minMiddle = _floor();
        bytes memory data = _order(address(usdt), _vaultTrader(), recipient);
        IYoMayanAdapter.SwapForwardParams memory p = _params(address(usdt), minMiddle, data);
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 forwarded = mayanAdapter.swapAndForwardERC20(p);

        // it should return amountIn / pull amountIn from the vault
        assertEq(forwarded, amount, "return value");
        assertEq(usdc.balanceOf(users.vault), vaultBefore - amount, "vault not debited");
        assertEq(usdc.balanceOf(address(mockMayanForwarder)), amount, "forwarder not credited");
        // it should forward swap params and mayanData to the forwarder
        (
            bool swap,
            address tokenIn,
            uint256 amountIn,
            address fSwapProtocol,
            address middleToken,
            uint256 minMiddleAmount,
            address mayanProtocol,
            bytes memory mayanData
        ) = mockMayanForwarder.last();
        assertTrue(swap, "should be swap path");
        assertEq(tokenIn, address(usdc), "tokenIn");
        assertEq(amountIn, amount, "amountIn");
        assertEq(fSwapProtocol, swapProtocol, "swapProtocol");
        assertEq(middleToken, address(usdt), "middleToken");
        assertEq(minMiddleAmount, minMiddle, "minMiddleAmount");
        assertEq(mayanProtocol, mayanSwift, "mayanProtocol not swift");
        assertEq(mayanData, data, "mayanData not forwarded verbatim");
        // it should reset forwarder allowance to zero
        assertZeroAllowance(address(usdc), address(mayanAdapter), address(mockMayanForwarder));
        assertZeroBalance(address(usdc), address(mayanAdapter));
    }
}
