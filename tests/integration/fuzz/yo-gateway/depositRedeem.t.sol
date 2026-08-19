// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoGatewayBase_Test } from "../../concrete/yo-gateway/YoGatewayBase.t.sol";

contract DepositRedeemYoGatewayIntegrationFuzzTest is YoGatewayBase_Test {
    /// @dev Deposit-then-redeem through the gateway is lossless on a 1:1 mock vault.
    function testFuzz_RoundTrip_Lossless(uint256 assets) external {
        assets = bound(assets, 1, 500_000e6);

        uint256 aliceBefore = usdc.balanceOf(users.alice);

        vm.startPrank(users.alice);
        uint256 shares = gateway.deposit(address(mockVault), assets, 1, users.alice, 0);
        // Re-approve gateway on shares (already done in base but cleared by `redeem` below if any).
        mockVault.approve(address(gateway), type(uint256).max);
        uint256 assetsBack = gateway.redeem(address(mockVault), shares, 1, users.alice, 0);
        vm.stopPrank();

        assertEq(assetsBack, assets, "round trip");
        assertEq(usdc.balanceOf(users.alice), aliceBefore, "alice USDC restored");
        assertEq(mockVault.balanceOf(users.alice), 0, "no leftover shares");
    }

    /// @dev minSharesOut just above the actual preview always reverts.
    function testFuzz_Deposit_RevertsAboveActualShares(uint256 assets) external {
        assets = bound(assets, 1, 500_000e6);
        uint256 expected = mockVault.previewDeposit(assets);

        vm.prank(users.alice);
        vm.expectRevert();
        gateway.deposit(address(mockVault), assets, expected + 1, users.alice, 0);
    }
}
