// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Offer } from "src/interfaces/IMidnight.sol";

import { Midnight_Integration_Shared } from "../../MidnightIntegration.t.sol";

/// @notice Fuzz `takeBuy`: for any units + max-assets slack the vault ends up spending exactly the
///         buyer assets, the adapter is left clean, and the credit delta equals the units bought.
contract TakeBuy_Integration_Fuzz_Test is Midnight_Integration_Shared {
    function testFuzz_TakeBuy_SweepsAndCredits(uint256 units, uint256 extra) external {
        units = bound(units, 1, 100_000e6);
        extra = bound(extra, 0, 100_000e6);
        uint256 maxAssets = units + extra; // always covers buyerAssets since unit price < 1

        Offer memory o = makerSellOffer();
        bytes32 id = marketId();
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        (uint256 buyerAssets, uint256 creditReceived) = midnightAdapter.takeBuy(o, "", units, maxAssets);

        assertEq(creditReceived, units, "credit delta == units");
        assertEq(usdc.balanceOf(users.vault), vaultBefore - buyerAssets, "vault net spend == buyerAssets");
        assertEq(mockMidnight.credit(id, users.vault), uint128(units), "vault credit");
        assertZeroBalance(address(usdc), address(midnightAdapter));
        assertZeroAllowance(address(usdc), address(midnightAdapter), address(mockMidnight));
    }
}
