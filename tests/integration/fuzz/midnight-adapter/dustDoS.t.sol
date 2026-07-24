// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Offer } from "src/interfaces/IMidnight.sol";

import { Midnight_Integration_Shared } from "../../MidnightIntegration.t.sol";

/// @notice Regression: pre-existing dust at the adapter (anyone can transfer loan token to it) must
///         not block `takeBuy`, and the adapter's full-balance sweep hands that dust to the vault
///         rather than stranding it. Mirrors the swap adapter's dust-sweep convention.
contract DustDoS_MidnightAdapter_Integration_Fuzz_Test is Midnight_Integration_Shared {
    function testFuzz_PreExistingDust_SweptToVault(uint256 dust, uint256 units) external {
        dust = bound(dust, 1, 1000e6);
        units = bound(units, 1, 100_000e6);
        uint256 maxAssets = units; // covers buyerAssets since unit price < 1

        usdc.mint(address(midnightAdapter), dust); // adversary dusts the adapter

        Offer memory o = makerSellOffer();
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        (uint256 buyerAssets,) = midnightAdapter.takeBuy(o, "", units, maxAssets);

        // Nothing stranded at the adapter; the dust followed the sweep to the vault.
        assertZeroBalance(address(usdc), address(midnightAdapter));
        assertEq(usdc.balanceOf(users.vault), vaultBefore - buyerAssets + dust, "dust swept to vault");
    }
}
