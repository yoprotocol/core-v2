// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IMayanSwift } from "src/interfaces/external/IMayanSwift.sol";
import { IYoMayanAdapter } from "src/interfaces/IYoMayanAdapter.sol";

import { MockERC20 } from "../../../mocks/MockERC20.sol";
import { Integration_Test } from "../../Integration.t.sol";

contract Forward_MayanAdapter_Integration_Fuzz_Test is Integration_Test {
    function _order(
        address orderTokenIn,
        uint256 orderAmountIn,
        bytes32 destAddr,
        uint16 destChainId
    )
        internal
        view
        returns (bytes memory)
    {
        IMayanSwift.OrderParams memory o = IMayanSwift.OrderParams({
            payloadType: 1,
            trader: bytes32(uint256(uint160(address(users.vault)))),
            destAddr: destAddr,
            destChainId: destChainId,
            referrerAddr: bytes32(0),
            tokenOut: bytes32(uint256(uint160(address(usdt)))),
            minAmountOut: 1,
            gasDrop: 0,
            cancelFee: 0,
            refundFee: 0,
            deadline: uint64(block.timestamp + 1 hours),
            referrerBps: 0,
            auctionMode: 2,
            random: bytes32(uint256(1))
        });
        return abi.encodeWithSelector(IMayanSwift.createOrderWithToken.selector, orderTokenIn, orderAmountIn, o, "");
    }

    function testFuzz_ForwardERC20_ValidRoute(uint256 amountIn, bytes32 destAddr, uint16 destChainId) external {
        amountIn = bound(amountIn, 1, usdc.balanceOf(users.vault));
        _allowRoute(users.vault, address(mayanAdapter), address(usdc), destChainId, destAddr);

        bytes memory data = _order(address(usdc), amountIn, destAddr, destChainId);
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 forwarded = mayanAdapter.forwardERC20(address(usdc), amountIn, data);

        assertEq(forwarded, amountIn, "return");
        assertEq(usdc.balanceOf(users.vault), vaultBefore - amountIn, "vault debit");
        (, address tokenIn,,,,, address mayanProtocol, bytes memory mayanData) = mockMayanForwarder.last();
        assertEq(tokenIn, address(usdc), "tokenIn");
        assertEq(mayanProtocol, mayanSwift, "swift");
        assertEq(mayanData, data, "data");
        assertZeroBalance(address(usdc), address(mayanAdapter));
        assertZeroAllowance(address(usdc), address(mayanAdapter), address(mockMayanForwarder));
    }

    function testFuzz_ForwardERC20_RevertWhen_ReferrerSet(uint8 referrerBps, bytes32 referrerAddr) external {
        vm.assume(referrerBps != 0 || referrerAddr != bytes32(0));
        uint256 amountIn = defaults.BRIDGE_AMOUNT();
        bytes32 destAddr = defaults.BRIDGE_RECIPIENT();
        uint16 destChainId = defaults.MAYAN_DEST_WORMHOLE_CHAIN();

        IMayanSwift.OrderParams memory o = IMayanSwift.OrderParams({
            payloadType: 1,
            trader: bytes32(uint256(uint160(address(users.vault)))),
            destAddr: destAddr,
            destChainId: destChainId,
            referrerAddr: referrerAddr,
            tokenOut: bytes32(uint256(uint160(address(usdt)))),
            minAmountOut: 1,
            gasDrop: 0,
            cancelFee: 0,
            refundFee: 0,
            deadline: uint64(block.timestamp + 1 hours),
            referrerBps: referrerBps,
            auctionMode: 2,
            random: bytes32(uint256(1))
        });
        bytes memory data =
            abi.encodeWithSelector(IMayanSwift.createOrderWithToken.selector, address(usdc), amountIn, o, "");

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMayanAdapter.ReferrerNotAllowed.selector, referrerAddr, referrerBps));
        mayanAdapter.forwardERC20(address(usdc), amountIn, data);
    }

    function testFuzz_ForwardERC20_RevertWhen_CustomPayloadSet(bytes memory customPayload) external {
        vm.assume(customPayload.length != 0);
        uint256 amountIn = defaults.BRIDGE_AMOUNT();
        bytes32 destAddr = defaults.BRIDGE_RECIPIENT();
        uint16 destChainId = defaults.MAYAN_DEST_WORMHOLE_CHAIN();

        IMayanSwift.OrderParams memory o = IMayanSwift.OrderParams({
            payloadType: 1,
            trader: bytes32(uint256(uint160(address(users.vault)))),
            destAddr: destAddr,
            destChainId: destChainId,
            referrerAddr: bytes32(0),
            tokenOut: bytes32(uint256(uint160(address(usdt)))),
            minAmountOut: 1,
            gasDrop: 0,
            cancelFee: 0,
            refundFee: 0,
            deadline: uint64(block.timestamp + 1 hours),
            referrerBps: 0,
            auctionMode: 2,
            random: bytes32(uint256(1))
        });
        bytes memory data = abi.encodeWithSelector(
            IMayanSwift.createOrderWithToken.selector, address(usdc), amountIn, o, customPayload
        );

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMayanAdapter.CustomPayloadNotAllowed.selector, customPayload.length));
        mayanAdapter.forwardERC20(address(usdc), amountIn, data);
    }

    function testFuzz_ForwardERC20_RevertWhen_RouteNotAllowed(bytes32 destAddr) external {
        vm.assume(destAddr != defaults.BRIDGE_RECIPIENT());
        uint256 amountIn = defaults.BRIDGE_AMOUNT();
        uint16 destChainId = defaults.MAYAN_DEST_WORMHOLE_CHAIN();

        bytes memory data = _order(address(usdc), amountIn, destAddr, destChainId);
        vm.prank(users.vault);
        vm.expectRevert();
        mayanAdapter.forwardERC20(address(usdc), amountIn, data);
    }

    /// @dev A REAL order captured from the Mayan SDK (`getSwapFromEvmTxPayload`): 25 WETH (Base) → ETH
    ///      (Wormhole chain 2), trader/refund = the vault, no referrer. Proves our Swift V2 struct
    ///      offsets extract tokenIn/amountIn/trader/destAddr/destChainId/referrer correctly from
    ///      genuine SDK output — a wrong layout would misread the guards or reject the order.
    function test_ForwardERC20_RealSdkPayload() external {
        address wethBase = 0x4200000000000000000000000000000000000006;
        address trader = 0x3A43AEC53490CB9Fa922847385D82fe25d0E9De7;
        bytes32 destAddr = bytes32(uint256(uint160(trader)));
        uint16 destChainId = 2;
        uint256 amountIn = 25e18;
        bytes memory payload = hex"a3a3083400000000000000000000000042000000000000000000000000000000"
            hex"000000060000000000000000000000000000000000000000000000015af1d78b"
            hex"58c4000000000000000000000000000000000000000000000000000000000000"
            hex"000000010000000000000000000000003a43aec53490cb9fa922847385d82fe2"
            hex"5d0e9de70000000000000000000000003a43aec53490cb9fa922847385d82fe2"
            hex"5d0e9de700000000000000000000000000000000000000000000000000000000"
            hex"0000000200000000000000000000000000000000000000000000000000000000"
            hex"00000000000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead908"
            hex"3c756cc200000000000000000000000000000000000000000000000000000000"
            hex"94cd06f400000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"0000207c00000000000000000000000000000000000000000000000000000000"
            hex"0000018c00000000000000000000000000000000000000000000000000000000"
            hex"6a4e2d1300000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"000000028409f07d6a7dc9ed21fec00e99d1d6304c43f329d55c2f2701841201"
            hex"dbe7264900000000000000000000000000000000000000000000000000000000"
            hex"0000022000000000000000000000000000000000000000000000000000000000" hex"00000000";

        // Make WETH (Base) a working ERC-20 at its canonical address and fund the order's trader.
        vm.etch(wethBase, address(new MockERC20("Wrapped Ether", "WETH", 18)).code);
        MockERC20(wethBase).mint(trader, amountIn);
        yoRegistry.setVault(trader, true);
        vm.prank(trader);
        MockERC20(wethBase).approve(address(mayanAdapter), amountIn);

        // Route not set → reverts with the destination decoded FROM THE REAL PAYLOAD (proves our
        // offsets read destChainId=2 and destAddr=trader out of the SDK order).
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(IYoMayanAdapter.RouteNotAllowed.selector, wethBase, destChainId, destAddr)
        );
        mayanAdapter.forwardERC20(wethBase, amountIn, payload);

        // Allowlist the exact route → the real order passes every guard and is forwarded verbatim.
        _allowRoute(trader, address(mayanAdapter), wethBase, destChainId, destAddr);
        vm.prank(trader);
        uint256 forwarded = mayanAdapter.forwardERC20(wethBase, amountIn, payload);

        assertEq(forwarded, amountIn, "return");
        (,,,,,, address mayanProtocol, bytes memory mayanData) = mockMayanForwarder.last();
        assertEq(mayanProtocol, mayanSwift, "forwarded to swift");
        assertEq(mayanData, payload, "payload forwarded verbatim");
    }
}
