// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "src/interfaces/IMorpho.sol";

import { Integration_Test } from "../../Integration.t.sol";

/// @notice Regression for the audit finding: pre-existing dust at the adapter address (anyone can
///         transfer 1 wei of `loanToken`) must NOT permanently DoS supply. The snapshot/delta
///         check only rejects what *this call* leaks.
contract DustDoS_MorphoAdapter_Integration_Fuzz_Test is Integration_Test {
    /// @dev Dust the adapter with `dust` wei of `loanToken`; supply must still succeed.
    function testFuzz_PreExistingDust_DoesNotBlockSupply(uint256 dust, uint256 assets) external {
        dust = bound(dust, 1, 1000e6);
        assets = bound(assets, 1, 1_000_000e6);

        usdc.mint(address(morphoAdapter), dust); // adversary dusts the adapter

        Id m = defaults.MARKET_A();
        vm.prank(users.vault);
        morphoAdapter.supply(m, assets);

        // Dust still parked at the adapter (no rescue path) but the call didn't revert.
        assertEq(usdc.balanceOf(address(morphoAdapter)), dust, "dust untouched");
    }
}
