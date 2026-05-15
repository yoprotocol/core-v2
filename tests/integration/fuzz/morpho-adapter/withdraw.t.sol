// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "src/interfaces/IMorpho.sol";

import { Integration_Test } from "../../Integration.t.sol";

contract Withdraw_Integration_Fuzz_Test is Integration_Test {
    function testFuzz_Withdraw_TransfersToVault(uint256 supplied, uint256 toWithdraw) external {
        supplied = bound(supplied, 2, 1_000_000e6);
        toWithdraw = bound(toWithdraw, 1, supplied);

        Id m = defaults.MARKET_A();

        vm.prank(users.vault);
        morphoAdapter.supply(m, supplied);

        uint256 vaultBalBefore = usdc.balanceOf(users.vault);
        uint256 sharesBefore = mockMorpho.position(m, users.vault).supplyShares;

        vm.prank(users.vault);
        (uint256 withdrawn,) = morphoAdapter.withdraw(m, toWithdraw);

        assertEq(withdrawn, toWithdraw, "assetsWithdrawn");
        assertEq(usdc.balanceOf(users.vault), vaultBalBefore + toWithdraw, "vault USDC delta");
        assertEq(mockMorpho.position(m, users.vault).supplyShares, sharesBefore - toWithdraw, "share burn (1:1 mock)");
        assertZeroBalance(address(usdc), address(morphoAdapter));
    }
}
