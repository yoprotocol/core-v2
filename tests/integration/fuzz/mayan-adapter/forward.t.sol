// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IMayanSwift } from "src/interfaces/external/IMayanSwift.sol";

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
            trader: bytes32(uint256(uint160(address(users.vault)))),
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

    function testFuzz_ForwardERC20_RevertWhen_RouteNotAllowed(bytes32 destAddr) external {
        vm.assume(destAddr != defaults.BRIDGE_RECIPIENT());
        uint256 amountIn = defaults.BRIDGE_AMOUNT();
        uint16 destChainId = defaults.MAYAN_DEST_WORMHOLE_CHAIN();

        bytes memory data = _order(address(usdc), amountIn, destAddr, destChainId);
        vm.prank(users.vault);
        vm.expectRevert();
        mayanAdapter.forwardERC20(address(usdc), amountIn, data);
    }
}
