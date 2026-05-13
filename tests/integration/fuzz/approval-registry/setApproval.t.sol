// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Integration_Test } from "../../Integration.t.sol";

contract SetApproval_Integration_Fuzz_Test is Integration_Test {
    function testFuzz_SetApproval_RoundTrips(
        address vault,
        address token,
        address spender,
        uint256 maxAmount
    )
        external
    {
        vm.assume(vault != address(0) && token != address(0) && spender != address(0));

        vm.prank(users.owner);
        approvalRegistry.setApproval(vault, token, spender, maxAmount);

        assertEq(approvalRegistry.maxApproval(vault, token, spender), maxAmount, "round trip");
    }

    /// @dev Distinct triples must not collide.
    function testFuzz_SetApproval_PerTripleIsolation(
        address vaultA,
        address vaultB,
        address token,
        address spender,
        uint256 maxA,
        uint256 maxB
    )
        external
    {
        vm.assume(vaultA != address(0) && vaultB != address(0) && vaultA != vaultB);
        vm.assume(token != address(0) && spender != address(0));

        vm.startPrank(users.owner);
        approvalRegistry.setApproval(vaultA, token, spender, maxA);
        approvalRegistry.setApproval(vaultB, token, spender, maxB);
        vm.stopPrank();

        assertEq(approvalRegistry.maxApproval(vaultA, token, spender), maxA, "vaultA cap");
        assertEq(approvalRegistry.maxApproval(vaultB, token, spender), maxB, "vaultB cap");
    }
}
