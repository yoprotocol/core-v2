// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Integration_Test } from "../../Integration.t.sol";

contract DepositForBurn_CctpAdapter_Integration_Fuzz_Test is Integration_Test {
    function testFuzz_DepositForBurn_PullsAndForwards(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold
    )
        external
    {
        amount = bound(amount, 1, usdc.balanceOf(users.vault));
        // `maxFee` is capped at `MAX_FEE_BPS` of the amount; fuzz within the allowed band.
        maxFee = bound(maxFee, 0, (amount * defaults.MAX_FEE_BPS()) / defaults.BPS_DENOMINATOR());

        _allowRoute(users.vault, address(cctpAdapter), address(usdc), destinationDomain, mintRecipient);

        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 burned =
            cctpAdapter.depositForBurn(amount, destinationDomain, mintRecipient, maxFee, minFinalityThreshold);

        assertEq(burned, amount, "return");
        assertEq(usdc.balanceOf(users.vault), vaultBefore - amount, "vault debit");
        assertEq(usdc.balanceOf(address(mockTokenMessenger)), amount, "messenger credit");

        (uint256 fAmount, uint32 fDomain, bytes32 fRecipient, address fBurnToken,,,) = mockTokenMessenger.last();
        assertEq(fAmount, amount, "amount");
        assertEq(fDomain, destinationDomain, "domain");
        assertEq(fRecipient, mintRecipient, "recipient");
        assertEq(fBurnToken, address(usdc), "burnToken");
        // Custody invariants.
        assertZeroBalance(address(usdc), address(cctpAdapter));
        assertZeroAllowance(address(usdc), address(cctpAdapter), address(mockTokenMessenger));
    }
}
