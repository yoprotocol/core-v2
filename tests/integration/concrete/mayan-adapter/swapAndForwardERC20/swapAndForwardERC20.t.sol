// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IMayanSwift } from "src/interfaces/external/IMayanSwift.sol";
import { IYoMayanAdapter } from "src/interfaces/IYoMayanAdapter.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract SwapAndForwardERC20_MayanAdapter_Integration_Concrete_Test is Integration_Test {
    uint16 private destChain;
    bytes32 private recipient;
    uint256 private amount;
    address private swapProtocol;
    uint256 private constant MIN_MIDDLE = 1;

    function setUp() public override {
        Integration_Test.setUp();
        destChain = defaults.MAYAN_DEST_WORMHOLE_CHAIN();
        recipient = defaults.BRIDGE_RECIPIENT();
        amount = defaults.BRIDGE_AMOUNT();
        swapProtocol = makeAddr("SwapProtocol");
    }

    /// @dev Build a Swift order whose declared input token is `orderTokenIn` (the middle token).
    function _order(address orderTokenIn, bytes32 trader, bytes32 destAddr) internal view returns (bytes memory) {
        IMayanSwift.OrderParams memory o = IMayanSwift.OrderParams({
            trader: trader,
            tokenOut: bytes32(uint256(uint160(address(usdc)))),
            minAmountOut: 1,
            gasDrop: 0,
            cancelFee: 0,
            refundFee: 0,
            deadline: uint64(block.timestamp + 1 hours),
            destAddr: destAddr,
            destChainId: destChain,
            referrerAddr: bytes32(0),
            referrerBps: 0,
            auctionMode: 2,
            random: bytes32(uint256(1))
        });
        // The order amount is a placeholder; the Forwarder rewrites it with the swap output.
        return abi.encodeWithSelector(IMayanSwift.createOrderWithToken.selector, orderTokenIn, uint256(0), o);
    }

    function _vaultTrader() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(users.vault))));
    }

    function _params(bytes memory mayanData) internal view returns (IYoMayanAdapter.SwapForwardParams memory) {
        return IYoMayanAdapter.SwapForwardParams({
            tokenIn: address(usdc),
            amountIn: amount,
            swapProtocol: swapProtocol,
            swapData: hex"",
            middleToken: address(usdt),
            minMiddleAmount: MIN_MIDDLE,
            mayanData: mayanData
        });
    }

    function test_WhenAmountInZero() external {
        IYoMayanAdapter.SwapForwardParams memory p = _params(_order(address(usdt), _vaultTrader(), recipient));
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
        IYoMayanAdapter.SwapForwardParams memory p = _params(_order(address(usdc), _vaultTrader(), recipient));
        vm.prank(users.vault);
        vm.expectRevert(IYoMayanAdapter.ProtocolDataMismatch.selector);
        mayanAdapter.swapAndForwardERC20(p);
    }

    function test_WhenTraderNotVault() external whenAmountInNonZero {
        bytes32 badTrader = bytes32(uint256(uint160(address(users.eve))));
        IYoMayanAdapter.SwapForwardParams memory p = _params(_order(address(usdt), badTrader, recipient));
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMayanAdapter.TraderNotVault.selector, badTrader));
        mayanAdapter.swapAndForwardERC20(p);
    }

    function test_WhenRouteNotAllowed() external whenAmountInNonZero {
        bytes32 badDest = bytes32(uint256(0xDEAD));
        IYoMayanAdapter.SwapForwardParams memory p = _params(_order(address(usdt), _vaultTrader(), badDest));
        vm.prank(users.vault);
        vm.expectRevert(
            abi.encodeWithSelector(IYoMayanAdapter.RouteNotAllowed.selector, address(usdc), destChain, badDest)
        );
        mayanAdapter.swapAndForwardERC20(p);
    }

    function test_WhenOrderValidAndRouteAllowed() external whenAmountInNonZero {
        bytes memory data = _order(address(usdt), _vaultTrader(), recipient);
        IYoMayanAdapter.SwapForwardParams memory p = _params(data);
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
        assertEq(minMiddleAmount, MIN_MIDDLE, "minMiddleAmount");
        assertEq(mayanProtocol, mayanSwift, "mayanProtocol not swift");
        assertEq(mayanData, data, "mayanData not forwarded verbatim");
        // it should reset forwarder allowance to zero
        assertZeroAllowance(address(usdc), address(mayanAdapter), address(mockMayanForwarder));
        assertZeroBalance(address(usdc), address(mayanAdapter));
    }
}
