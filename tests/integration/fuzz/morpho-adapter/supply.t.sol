// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "src/interfaces/IMorpho.sol";
import { IYoMorphoAdapter } from "src/interfaces/IYoMorphoAdapter.sol";

import { Integration_Test } from "../../Integration.t.sol";

/// @notice Fuzz the supply path. Mirrors the BTT happy-path branches with random inputs.
contract Supply_Integration_Fuzz_Test is Integration_Test {
    uint256 private constant FUZZ_MIN = 1;
    uint256 private constant FUZZ_MAX = 1_000_000e6;

    function testFuzz_Supply_PullsAndSettles(uint256 assets) external {
        assets = bound(assets, FUZZ_MIN, FUZZ_MAX);

        Id m = defaults.MARKET_A();
        uint256 vaultBalBefore = usdc.balanceOf(users.vault);
        uint256 sharesBefore = mockMorpho.position(m, users.vault).supplyShares;

        vm.prank(users.vault);
        (uint256 supplied, uint256 sharesSupplied) = morphoAdapter.supply(m, assets);

        assertEq(supplied, assets, "assetsSupplied == assets");
        assertGt(sharesSupplied, 0, "non-zero shares");
        assertEq(usdc.balanceOf(users.vault), vaultBalBefore - assets, "vault USDC delta");
        assertEq(
            mockMorpho.position(m, users.vault).supplyShares, sharesBefore + assets, "share delta == assets (1:1 mock)"
        );
        assertZeroBalance(address(usdc), address(morphoAdapter));
        assertZeroAllowance(address(usdc), address(morphoAdapter), address(mockMorpho));
    }

    function testFuzz_Supply_RevertsWhenAmountZero(uint256 _seed) external {
        _seed; // unused; here so the fuzzer schedules the test like the others.
        Id m = defaults.MARKET_A();
        vm.prank(users.vault);
        vm.expectRevert(IYoMorphoAdapter.InvalidAmount.selector);
        morphoAdapter.supply(m, 0);
    }
}
