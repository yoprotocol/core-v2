// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { IMayanSwift } from "src/interfaces/external/IMayanSwift.sol";
import { IYoMayanAdapter } from "src/interfaces/IYoMayanAdapter.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract ForwardERC20_MayanAdapter_Integration_Concrete_Test is Integration_Test {
    uint16 private destChain;
    bytes32 private recipient;
    uint256 private amount;

    function setUp() public override {
        Integration_Test.setUp();
        destChain = defaults.MAYAN_DEST_WORMHOLE_CHAIN();
        recipient = defaults.BRIDGE_RECIPIENT();
        amount = defaults.BRIDGE_AMOUNT();
    }

    /// @dev Build a Swift `createOrderWithToken` order for `(orderTokenIn, orderAmountIn)`.
    function _order(
        address orderTokenIn,
        uint256 orderAmountIn,
        bytes32 trader,
        bytes32 destAddr,
        uint16 destChainId
    )
        internal
        view
        returns (bytes memory)
    {
        IMayanSwift.OrderParams memory o = IMayanSwift.OrderParams({
            trader: trader,
            tokenOut: bytes32(uint256(uint160(address(usdt)))),
            minAmountOut: 1,
            gasDrop: 0,
            cancelFee: 0,
            refundFee: 0,
            deadline: uint64(block.timestamp + 1 hours),
            destAddr: destAddr,
            destChainId: destChainId,
            referrerAddr: bytes32(0),
            referrerBps: 0,
            auctionMode: 2,
            random: bytes32(uint256(1))
        });
        return abi.encodeWithSelector(IMayanSwift.createOrderWithToken.selector, orderTokenIn, orderAmountIn, o);
    }

    function _vaultTrader() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(users.vault))));
    }

    function test_WhenAmountInZero() external {
        bytes memory data = _order(address(usdc), 0, _vaultTrader(), recipient, destChain);
        vm.prank(users.vault);
        vm.expectRevert(IYoMayanAdapter.InvalidAmount.selector);
        mayanAdapter.forwardERC20(address(usdc), 0, data);
    }

    modifier whenAmountInNonZero() {
        _;
    }

    function test_WhenProtocolDataSelectorNotCreateOrderWithToken() external whenAmountInNonZero {
        bytes memory bad = hex"12345678";
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMayanAdapter.UnsupportedProtocolData.selector, bytes4(0x12345678)));
        mayanAdapter.forwardERC20(address(usdc), amount, bad);
    }

    function test_WhenOrderTokenOrAmountMismatch() external whenAmountInNonZero {
        // Order declares amountIn+1, mismatching the forwarded amountIn.
        bytes memory data = _order(address(usdc), amount + 1, _vaultTrader(), recipient, destChain);
        vm.prank(users.vault);
        vm.expectRevert(IYoMayanAdapter.ProtocolDataMismatch.selector);
        mayanAdapter.forwardERC20(address(usdc), amount, data);
    }

    function test_WhenTraderNotVault() external whenAmountInNonZero {
        bytes32 badTrader = bytes32(uint256(uint160(address(users.eve))));
        bytes memory data = _order(address(usdc), amount, badTrader, recipient, destChain);
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMayanAdapter.TraderNotVault.selector, badTrader));
        mayanAdapter.forwardERC20(address(usdc), amount, data);
    }

    function test_WhenRouteNotAllowed() external whenAmountInNonZero {
        bytes32 badDest = bytes32(uint256(0xDEAD));
        bytes memory data = _order(address(usdc), amount, _vaultTrader(), badDest, destChain);
        vm.prank(users.vault);
        vm.expectRevert(
            abi.encodeWithSelector(IYoMayanAdapter.RouteNotAllowed.selector, address(usdc), destChain, badDest)
        );
        mayanAdapter.forwardERC20(address(usdc), amount, data);
    }

    function test_WhenOrderValidAndRouteAllowed() external whenAmountInNonZero {
        bytes memory data = _order(address(usdc), amount, _vaultTrader(), recipient, destChain);
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.expectEmit(true, true, true, true, address(mayanAdapter));
        emit YoAdapterBase.AdapterAction(
            users.vault,
            address(mockMayanForwarder),
            address(usdc),
            YoAdapterBase.AdapterDirection.Bridge,
            amount
        );

        vm.prank(users.vault);
        uint256 forwarded = mayanAdapter.forwardERC20(address(usdc), amount, data);

        // it should return amountIn / pull amountIn from the vault
        assertEq(forwarded, amount, "return value");
        assertEq(usdc.balanceOf(users.vault), vaultBefore - amount, "vault not debited");
        assertEq(usdc.balanceOf(address(mockMayanForwarder)), amount, "forwarder not credited");
        // it should forward to the swift protocol with protocolData
        (bool swap, address tokenIn,,,,, address mayanProtocol, bytes memory mayanData) = mockMayanForwarder.last();
        assertFalse(swap, "should be non-swap path");
        assertEq(tokenIn, address(usdc), "tokenIn");
        assertEq(mayanProtocol, mayanSwift, "mayanProtocol not swift");
        assertEq(mayanData, data, "protocolData not forwarded verbatim");
        // it should reset forwarder allowance to zero
        assertZeroAllowance(address(usdc), address(mayanAdapter), address(mockMayanForwarder));
        assertZeroBalance(address(usdc), address(mayanAdapter));
    }
}
