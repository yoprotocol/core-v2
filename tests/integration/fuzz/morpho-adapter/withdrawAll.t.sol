// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "src/interfaces/IMorpho.sol";

import { Integration_Test } from "../../Integration.t.sol";

contract WithdrawAll_MorphoAdapter_Integration_Fuzz_Test is Integration_Test {
    /// @dev After `supply(assets)` then `withdrawAll()`, the vault's USDC balance is restored and
    ///      its Morpho position has zero supply shares.
    function testFuzz_WithdrawAll_ClosesPositionFully(uint256 assets) external {
        assets = bound(assets, 1, 1_000_000e6);

        Id m = defaults.MARKET_A();
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.startPrank(users.vault);
        morphoAdapter.supply(m, assets);
        (uint256 assetsBack,) = morphoAdapter.withdrawAll(m);
        vm.stopPrank();

        assertEq(assetsBack, assets, "round-trip");
        assertEq(usdc.balanceOf(users.vault), vaultBefore, "vault USDC restored");
        assertEq(mockMorpho.position(m, users.vault).supplyShares, 0, "position closed");
        // Custody invariants
        assertZeroBalance(address(usdc), address(morphoAdapter));
    }
}
