// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Market } from "src/interfaces/IMidnight.sol";

import { Midnight_Integration_Shared } from "../../MidnightIntegration.t.sol";

/// @notice Fuzz `withdrawAll`: it always redeems `min(credit, withdrawable)` and never underflows
///         Midnight, regardless of how the two values relate.
contract WithdrawAll_Integration_Fuzz_Test is Midnight_Integration_Shared {
    function testFuzz_WithdrawAll_RedeemsMin(uint256 creditSeed, uint256 withdrawableSeed) external {
        creditSeed = bound(creditSeed, 1, 200_000e6);
        withdrawableSeed = bound(withdrawableSeed, 1, 200_000e6);

        bytes32 id = marketId();
        mockMidnight.setCredit(id, users.vault, uint128(creditSeed));
        mockMidnight.setWithdrawable(id, uint128(withdrawableSeed));

        uint256 expected = creditSeed < withdrawableSeed ? creditSeed : withdrawableSeed;
        Market memory m = market();
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 units = midnightAdapter.withdrawAll(m);

        assertEq(units, expected, "redeems min(credit, withdrawable)");
        assertEq(usdc.balanceOf(users.vault), vaultBefore + expected, "vault received redeemed units");
        assertEq(mockMidnight.credit(id, users.vault), uint128(creditSeed - expected), "credit reduced by redeemed");
    }
}
