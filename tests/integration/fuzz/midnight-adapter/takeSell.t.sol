// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Offer } from "src/interfaces/IMidnight.sol";
import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";

import { Midnight_Integration_Shared } from "../../MidnightIntegration.t.sol";

/// @notice Fuzz `takeSell`: proceeds settle to the vault, credit drops by exactly the units sold,
///         and the lender-only guard rejects any sale exceeding the vault's credit.
contract TakeSell_Integration_Fuzz_Test is Midnight_Integration_Shared {
    function testFuzz_TakeSell_SettlesToVault(uint256 units, uint256 creditSeed) external {
        units = bound(units, 1, 100_000e6);
        creditSeed = bound(creditSeed, units, 200_000e6);

        bytes32 id = marketId();
        mockMidnight.setCredit(id, users.vault, uint128(creditSeed));
        _fundMaker(200_000e6);

        uint256 expected = (units * 99) / 100; // floor(units * 0.99)
        Offer memory o = makerBuyOffer();
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 sellerAssets = midnightAdapter.takeSell(o, "", units, expected);

        assertEq(sellerAssets, expected, "sellerAssets == floor(units * price)");
        assertEq(usdc.balanceOf(users.vault), vaultBefore + expected, "vault received proceeds");
        assertEq(mockMidnight.credit(id, users.vault), uint128(creditSeed - units), "credit reduced by units");
    }

    function testFuzz_TakeSell_RevertsWhenCreditBelowUnits(uint256 units, uint256 creditSeed) external {
        units = bound(units, 2, 100_000e6);
        creditSeed = bound(creditSeed, 0, units - 1);

        bytes32 id = marketId();
        mockMidnight.setCredit(id, users.vault, uint128(creditSeed));
        _fundMaker(200_000e6);

        Offer memory o = makerBuyOffer();
        vm.prank(users.vault);
        vm.expectRevert(IYoMidnightAdapter.InsufficientCredit.selector);
        midnightAdapter.takeSell(o, "", units, 0);
    }
}
