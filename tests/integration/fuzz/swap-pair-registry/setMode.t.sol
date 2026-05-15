// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoSwapPairRegistry } from "src/interfaces/IYoSwapPairRegistry.sol";

import { Integration_Test } from "../../Integration.t.sol";

contract SetMode_SwapPairRegistry_Integration_Fuzz_Test is Integration_Test {
    function testFuzz_SetMode_RoundTrips(address vault, address tokenIn, address tokenOut, uint8 modeRaw) external {
        vm.assume(vault != address(0) && tokenIn != address(0) && tokenOut != address(0));
        vm.assume(tokenIn != tokenOut);
        // PairMode has 3 variants: DISALLOWED, ORACLE_CHECKED, OPERATOR_TRUSTED.
        IYoSwapPairRegistry.PairMode mode = IYoSwapPairRegistry.PairMode(modeRaw % 3);

        vm.prank(users.owner);
        pairRegistry.setMode(vault, tokenIn, tokenOut, mode);

        assertEq(uint256(pairRegistry.modeOf(vault, tokenIn, tokenOut)), uint256(mode), "round trip");
        assertEq(
            pairRegistry.isAllowed(vault, tokenIn, tokenOut),
            mode != IYoSwapPairRegistry.PairMode.DISALLOWED,
            "isAllowed iff mode != DISALLOWED"
        );
    }

    /// @dev Direction matters: setting (A, B) does NOT set (B, A).
    function testFuzz_SetMode_DirectionIsolated(
        address vault,
        address tokenIn,
        address tokenOut,
        uint8 modeRaw
    )
        external
    {
        vm.assume(vault != address(0) && tokenIn != address(0) && tokenOut != address(0));
        vm.assume(tokenIn != tokenOut);
        // Pick ORACLE_CHECKED or OPERATOR_TRUSTED (skip DISALLOWED for the allowlist-direction test).
        IYoSwapPairRegistry.PairMode mode = IYoSwapPairRegistry.PairMode((modeRaw % 2) + 1);

        vm.prank(users.owner);
        pairRegistry.setMode(vault, tokenIn, tokenOut, mode);

        assertTrue(pairRegistry.isAllowed(vault, tokenIn, tokenOut));
        assertFalse(pairRegistry.isAllowed(vault, tokenOut, tokenIn), "reverse direction not allowed");
    }

    function testFuzz_SetMode_RevertsOnSameToken(address vault, address token, uint8 modeRaw) external {
        vm.assume(vault != address(0) && token != address(0));
        IYoSwapPairRegistry.PairMode mode = IYoSwapPairRegistry.PairMode(modeRaw % 3);

        vm.prank(users.owner);
        vm.expectRevert();
        pairRegistry.setMode(vault, token, token, mode);
    }
}
