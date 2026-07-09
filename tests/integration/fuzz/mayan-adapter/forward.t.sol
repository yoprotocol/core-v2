// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IMayanSwift } from "src/interfaces/external/IMayanSwift.sol";
import { IYoMayanAdapter } from "src/interfaces/IYoMayanAdapter.sol";

import { MockERC20 } from "../../../mocks/MockERC20.sol";
import { Integration_Test } from "../../Integration.t.sol";
import { MayanOrders } from "../../../utils/MayanOrders.sol";

contract Forward_MayanAdapter_Integration_Fuzz_Test is Integration_Test {
    // Real Base-mainnet addresses + swap calldata for the cbBTC→cbBTC Swift route (10 cbBTC), captured
    // from the Mayan quote API. Swift swaps cbBTC→USDC on the source via `MAYAN_SWAP_ROUTER`, then
    // bridges. `_REAL_SWAP_DATA` is the exact `evmSwapRouterCalldata` returned by the quote.
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant MAYAN_SWAP_ROUTER = 0x0000000000001fF3684f28c67538d4D072C22734;
    // solhint-disable-next-line max-line-length
    bytes private constant _REAL_SWAP_DATA = hex"2213bc0b0000000000000000000000007747f8d2a76bd6345cc29622a946a929647f2359000000000000000000000000cbb7"
        hex"c0000ab88b473b1f5afd9ef808440eed33bf000000000000000000000000000000000000000000000000000000003b9aca00"
        hex"0000000000000000000000007747f8d2a76bd6345cc29622a946a929647f2359000000000000000000000000000000000000"
        hex"00000000000000000000000000a000000000000000000000000000000000000000000000000000000000000004c41fff991f"
        hex"000000000000000000000000337685fdab40d39bd02028545a4ffa7d287cc3e2000000000000000000000000833589fcd6ed"
        hex"b6e08f4c7c32d4f71b54bda0291300000000000000000000000000000000000000000000000000000080981ea4d800000000"
        hex"000000000000000000000000000000000000000000000000000000a037364b2680edf43b0f4a386e00000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000000000000000000000030000000000000000"
        hex"0000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000"
        hex"0000000002200000000000000000000000000000000000000000000000000000000000000340000000000000000000000000"
        hex"00000000000000000000000000000000000001843036d6a60000000000000000000000007747f8d2a76bd6345cc29622a946"
        hex"a929647f2359000000000000000000000000cbb7c0000ab88b473b1f5afd9ef808440eed33bf000000000000000000000000"
        hex"000000000000000000000000000000003b9aca00000000000000000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000006a4e58bd00000000000000000000000000000000"
        hex"0000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001600000"
        hex"0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        hex"000000000000000000000040cbb7c0000ab88b473b1f5afd9ef808440eed33bf04000064fffd8963efd1fc6a506488495d95"
        hex"1d5263988d254200000000000000000000000000000000000006000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000e48d68a1560000000000000000000000007747f8d2a76bd6345cc29622a946a929"
        hex"647f235900000000000000000000000000000000000000000000000000000000000027100000000000000000000000000000"
        hex"0000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000040420000000000000000000000000000000000"
        hex"000600000bb800000000000000000000000000000001000276a4833589fcd6edb6e08f4c7c32d4f71b54bda0291300000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        hex"00000000008434ee90ca000000000000000000000000f5c4f3dc02c3fb9279495a8fef7b0741da9561570000000000000000"
        hex"00000000833589fcd6edb6e08f4c7c32d4f71b54bda029130000000000000000000000000000000000000000000000000000"
        hex"008ee1e94b070000000000000000000000000000000000000000000000000000000000002710000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    function _vaultTrader() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(users.vault))));
    }

    /// @dev Default valid order: trader = vault, tokenOut = usdt (same-asset), `minAmountOut` the full
    ///      input (usdc/usdt are 6-dp so normalized == native), clearing the delivery floor.
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
        return _orderWithMinOut(orderTokenIn, orderAmountIn, destAddr, destChainId, uint64(orderAmountIn));
    }

    /// @dev As `_order` but with an explicit `minAmountOut`, to exercise the delivery floor.
    function _orderWithMinOut(
        address orderTokenIn,
        uint256 orderAmountIn,
        bytes32 destAddr,
        uint16 destChainId,
        uint64 minAmountOut
    )
        internal
        view
        returns (bytes memory)
    {
        return MayanOrders.encode(
            orderTokenIn,
            orderAmountIn,
            MayanOrders.order(_vaultTrader(), destAddr, destChainId, address(usdt), minAmountOut)
        );
    }

    function testFuzz_ForwardERC20_ValidRoute(uint256 amountIn, bytes32 destAddr, uint16 destChainId) external {
        amountIn = bound(amountIn, 1, usdc.balanceOf(users.vault));
        // Route pins the order's tokenOut (usdt in `_order`).
        _allowRoute(
            users.vault,
            address(mayanAdapter),
            address(usdc),
            destChainId,
            destAddr,
            bytes32(uint256(uint160(address(usdt))))
        );

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

        IMayanSwift.OrderParams memory o =
            MayanOrders.order(_vaultTrader(), destAddr, destChainId, address(usdt), uint64(amountIn));
        o.referrerAddr = referrerAddr;
        o.referrerBps = referrerBps;
        bytes memory data = MayanOrders.encode(address(usdc), amountIn, o);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMayanAdapter.ReferrerNotAllowed.selector, referrerAddr, referrerBps));
        mayanAdapter.forwardERC20(address(usdc), amountIn, data);
    }

    function test_ForwardERC20_RevertWhen_OrderFeeTooHigh() external {
        uint256 amountIn = defaults.BRIDGE_AMOUNT();
        bytes32 destAddr = defaults.BRIDGE_RECIPIENT();
        uint16 destChainId = defaults.MAYAN_DEST_WORMHOLE_CHAIN();
        _allowRoute(
            users.vault,
            address(mayanAdapter),
            address(usdc),
            destChainId,
            destAddr,
            bytes32(uint256(uint160(address(usdt))))
        );

        // usdc is 6 decimals (≤ 8) → Swift-normalized amount == native; cap = amountIn * maxOrderFeeBps / 10_000.
        uint256 cap = (amountIn * mayanAdapter.maxOrderFeeBps()) / 10_000;

        IMayanSwift.OrderParams memory o =
            MayanOrders.order(_vaultTrader(), destAddr, destChainId, address(usdt), uint64(amountIn));
        o.cancelFee = uint64(cap + 1); // one wei over the cap
        bytes memory data = MayanOrders.encode(address(usdc), amountIn, o);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMayanAdapter.OrderFeeTooHigh.selector, cap + 1, cap));
        mayanAdapter.forwardERC20(address(usdc), amountIn, data);
    }

    function test_ForwardERC20_RevertWhen_MinAmountOutTooLow() external {
        uint256 amountIn = defaults.BRIDGE_AMOUNT();
        bytes32 destAddr = defaults.BRIDGE_RECIPIENT();
        uint16 destChainId = defaults.MAYAN_DEST_WORMHOLE_CHAIN();
        _allowRoute(
            users.vault,
            address(mayanAdapter),
            address(usdc),
            destChainId,
            destAddr,
            bytes32(uint256(uint160(address(usdt))))
        );

        // usdc is 6-dp (≤ 8) → normalized == native; floor = amountIn * (BPS - maxBridgeSlippageBps) / BPS.
        uint256 floor =
            (amountIn * (defaults.BPS_DENOMINATOR() - defaults.MAX_BRIDGE_SLIPPAGE_BPS())) / defaults.BPS_DENOMINATOR();

        // `_order` sets minAmountOut = amountIn (clears the floor); rebuild with one wei below the floor.
        bytes memory data = _orderWithMinOut(address(usdc), amountIn, destAddr, destChainId, uint64(floor - 1));

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMayanAdapter.MinAmountOutTooLow.selector, floor - 1, floor));
        mayanAdapter.forwardERC20(address(usdc), amountIn, data);
    }

    function test_ForwardERC20_RevertWhen_InvalidPayloadType() external {
        uint256 amountIn = defaults.BRIDGE_AMOUNT();
        bytes32 destAddr = defaults.BRIDGE_RECIPIENT();
        uint16 destChainId = defaults.MAYAN_DEST_WORMHOLE_CHAIN();

        IMayanSwift.OrderParams memory o =
            MayanOrders.order(_vaultTrader(), destAddr, destChainId, address(usdt), uint64(amountIn));
        o.payloadType = 2; // Swift's payload-delivery variant — must be rejected.
        bytes memory data = MayanOrders.encode(address(usdc), amountIn, o);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMayanAdapter.InvalidPayloadType.selector, uint8(2)));
        mayanAdapter.forwardERC20(address(usdc), amountIn, data);
    }

    function test_ForwardERC20_RevertWhen_InvalidAuctionMode() external {
        uint256 amountIn = defaults.BRIDGE_AMOUNT();
        bytes32 destAddr = defaults.BRIDGE_RECIPIENT();
        uint16 destChainId = defaults.MAYAN_DEST_WORMHOLE_CHAIN();

        IMayanSwift.OrderParams memory o =
            MayanOrders.order(_vaultTrader(), destAddr, destChainId, address(usdt), uint64(amountIn));
        o.auctionMode = 1; // BYPASS — must be rejected; only ENGLISH (2) is accepted.
        bytes memory data = MayanOrders.encode(address(usdc), amountIn, o);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMayanAdapter.InvalidAuctionMode.selector, uint8(1)));
        mayanAdapter.forwardERC20(address(usdc), amountIn, data);
    }

    function testFuzz_ForwardERC20_RevertWhen_CustomPayloadSet(bytes memory customPayload) external {
        vm.assume(customPayload.length != 0);
        uint256 amountIn = defaults.BRIDGE_AMOUNT();
        bytes32 destAddr = defaults.BRIDGE_RECIPIENT();
        uint16 destChainId = defaults.MAYAN_DEST_WORMHOLE_CHAIN();

        // Encode with a non-empty customPayload (MayanOrders.encode always uses ""), so build directly.
        IMayanSwift.OrderParams memory o =
            MayanOrders.order(_vaultTrader(), destAddr, destChainId, address(usdt), uint64(amountIn));
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

        // Allowlist the exact route, pinning the order's real tokenOut (WETH mainnet, from the SDK
        // payload) → the real order passes every guard and is forwarded verbatim.
        _allowRoute(
            trader,
            address(mayanAdapter),
            wethBase,
            destChainId,
            destAddr,
            bytes32(uint256(uint160(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)))
        );
        vm.prank(trader);
        uint256 forwarded = mayanAdapter.forwardERC20(wethBase, amountIn, payload);

        assertEq(forwarded, amountIn, "return");
        (,,,,,, address mayanProtocol, bytes memory mayanData) = mockMayanForwarder.last();
        assertEq(mayanProtocol, mayanSwift, "forwarded to swift");
        assertEq(mayanData, payload, "payload forwarded verbatim");
    }

    /// @dev Wire cbBTC (8dec) + USDC (6dec) as working ERC-20s at their real Base addresses, fund and
    ///      approve the vault, allowlist the cbBTC→USDC swap pair (`ORACLE_CHECKED`) with an oracle
    ///      rate (~$61,060/cbBTC) matching the quote, and allowlist the cbBTC→Ethereum route pinning
    ///      the destination token. Returns the destination address used by the order.
    function _realSwapSetup() internal returns (bytes32 destAddr) {
        vm.etch(CBBTC, address(new MockERC20("cbBTC", "cbBTC", 8)).code);
        vm.etch(USDC_BASE, address(new MockERC20("USD Coin", "USDC", 6)).code);
        MockERC20(CBBTC).mint(users.vault, 10e8);
        vm.prank(users.vault);
        MockERC20(CBBTC).approve(address(mayanAdapter), 10e8);

        _allowPair(users.vault, CBBTC, USDC_BASE);
        // getQuote(CBBTC, USDC_BASE, 10e8) == 610_607_140_923 (≈ the quote's minMiddleAmount).
        mockOracle.setQuote(CBBTC, USDC_BASE, 610_607_140_923_000_000_000);

        destAddr = bytes32(uint256(uint160(address(0xBEEF))));
        _allowRoute(users.vault, address(mayanAdapter), CBBTC, 2, destAddr, bytes32(uint256(uint160(CBBTC))));
    }

    function _realSwapParams(
        bytes32 destAddr,
        uint256 minMiddleAmount
    )
        internal
        view
        returns (IYoMayanAdapter.SwapForwardParams memory)
    {
        IMayanSwift.OrderParams memory o = IMayanSwift.OrderParams({
            payloadType: 1,
            trader: bytes32(uint256(uint160(address(users.vault)))),
            destAddr: destAddr,
            destChainId: 2, // Wormhole chain id: Ethereum
            referrerAddr: bytes32(0),
            tokenOut: bytes32(uint256(uint160(CBBTC))), // cbBTC on Ethereum (same address)
            minAmountOut: 982_938_056, // 9.82938056 cbBTC from the quote
            gasDrop: 0,
            cancelFee: 0,
            refundFee: 0,
            deadline: uint64(block.timestamp + 1 hours),
            referrerBps: 0,
            auctionMode: 2,
            random: bytes32(uint256(1))
        });
        bytes memory mayanData =
            abi.encodeWithSelector(IMayanSwift.createOrderWithToken.selector, USDC_BASE, uint256(0), o, "");
        return IYoMayanAdapter.SwapForwardParams({
            tokenIn: CBBTC,
            amountIn: 10e8,
            swapProtocol: MAYAN_SWAP_ROUTER,
            swapData: _REAL_SWAP_DATA,
            middleToken: USDC_BASE,
            minMiddleAmount: minMiddleAmount,
            mayanData: mayanData
        });
    }

    /// @dev Real Mayan swap-route payload: the adapter's swap-leg checks (pair allowlist + oracle
    ///      floor + tokenOut pin) accept the quote's `minMiddleAmount` and forward the real swap
    ///      protocol + calldata + Swift order verbatim.
    function test_SwapAndForwardERC20_RealMayanQuote() external {
        bytes32 destAddr = _realSwapSetup();
        IYoMayanAdapter.SwapForwardParams memory p = _realSwapParams(destAddr, 610_607_140_923);

        vm.prank(users.vault);
        uint256 forwarded = mayanAdapter.swapAndForwardERC20(p);

        assertEq(forwarded, 10e8, "return");
        (
            bool swap,
            address tokenIn,,
            address swapProtocol,
            address middleToken,
            uint256 minMiddleAmount,
            address mayanProtocol,
            bytes memory mayanData
        ) = mockMayanForwarder.last();
        assertTrue(swap, "swap path");
        assertEq(tokenIn, CBBTC, "tokenIn");
        assertEq(swapProtocol, MAYAN_SWAP_ROUTER, "real swap protocol");
        assertEq(middleToken, USDC_BASE, "middle token");
        assertEq(minMiddleAmount, 610_607_140_923, "minMiddleAmount");
        assertEq(mayanProtocol, mayanSwift, "forwarded to swift");
        assertEq(mayanData, p.mayanData, "order forwarded verbatim");
        assertEq(mockMayanForwarder.lastSwapData(), _REAL_SWAP_DATA, "real swap calldata forwarded verbatim");
        assertZeroBalance(CBBTC, address(mayanAdapter));
        assertZeroAllowance(CBBTC, address(mayanAdapter), address(mockMayanForwarder));
    }

    /// @dev Same real route, but a `minMiddleAmount` below the oracle floor is rejected — proving the
    ///      swap-leg floor guards the real cbBTC→USDC leg against an under-priced swap.
    function test_SwapAndForwardERC20_RealMayanQuote_RevertBelowFloor() external {
        bytes32 destAddr = _realSwapSetup();
        uint256 floor = (mockOracle.getQuote(CBBTC, USDC_BASE, 10e8) * (10_000 - defaults.MAX_SLIPPAGE_BPS())) / 10_000;
        IYoMayanAdapter.SwapForwardParams memory p = _realSwapParams(destAddr, floor - 1);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMayanAdapter.SlippageTooLow.selector, floor - 1, floor));
        mayanAdapter.swapAndForwardERC20(p);
    }
}
