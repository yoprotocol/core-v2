// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "src/interfaces/IMorpho.sol";

import { Integration_Test } from "../../Integration.t.sol";

contract SetAllowed_MorphoMarketRegistry_Integration_Fuzz_Test is Integration_Test {
    function testFuzz_SetAllowed_RoundTrips(address vault, Id marketId, bool allowed) external {
        vm.assume(vault != address(0));

        vm.prank(users.owner);
        marketRegistry.setAllowed(vault, marketId, allowed);

        assertEq(marketRegistry.isAllowed(vault, marketId), allowed, "round trip");
    }

    /// @dev Distinct (vault, marketId) pairs do not collide.
    function testFuzz_SetAllowed_PerPairIsolation(
        address vaultA,
        address vaultB,
        Id marketId,
        bool flagA,
        bool flagB
    )
        external
    {
        vm.assume(vaultA != address(0) && vaultB != address(0) && vaultA != vaultB);

        vm.startPrank(users.owner);
        marketRegistry.setAllowed(vaultA, marketId, flagA);
        marketRegistry.setAllowed(vaultB, marketId, flagB);
        vm.stopPrank();

        assertEq(marketRegistry.isAllowed(vaultA, marketId), flagA);
        assertEq(marketRegistry.isAllowed(vaultB, marketId), flagB);
    }

    function testFuzz_SetAllowed_RevertsOnUnauthorizedCaller(address caller, address vault, Id m) external {
        vm.assume(caller != users.owner);
        vm.assume(vault != address(0));

        vm.prank(caller);
        vm.expectRevert();
        marketRegistry.setAllowed(vault, m, true);
    }
}
