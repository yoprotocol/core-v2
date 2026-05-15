// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoGatewayBase_Test } from "../../concrete/yo-gateway/YoGatewayBase.t.sol";

contract Quotes_YoGateway_Integration_Fuzz_Test is YoGatewayBase_Test {
    /// @dev All five quote functions are thin pass-throughs to the vault. For any amount the
    ///      gateway's return value equals the vault's own preview/convert function.
    function testFuzz_AllQuotes_MirrorVault(uint256 amount) external view {
        amount = bound(amount, 0, 1e30);

        assertEq(
            gateway.quoteConvertToShares(address(mockVault), amount),
            mockVault.convertToShares(amount),
            "convertToShares"
        );
        assertEq(
            gateway.quoteConvertToAssets(address(mockVault), amount),
            mockVault.convertToAssets(amount),
            "convertToAssets"
        );
        assertEq(
            gateway.quotePreviewDeposit(address(mockVault), amount),
            mockVault.previewDeposit(amount),
            "previewDeposit"
        );
        assertEq(
            gateway.quotePreviewRedeem(address(mockVault), amount),
            mockVault.previewRedeem(amount),
            "previewRedeem"
        );
        assertEq(
            gateway.quotePreviewWithdraw(address(mockVault), amount),
            mockVault.previewWithdraw(amount),
            "previewWithdraw"
        );
    }

    /// @dev Allowance views also mirror the underlying ERC-20.
    function testFuzz_Allowance_MirrorsERC20(address owner) external view {
        vm.assume(owner != address(0));
        assertEq(
            gateway.getShareAllowance(address(mockVault), owner),
            mockVault.allowance(owner, address(gateway))
        );
        assertEq(
            gateway.getAssetAllowance(address(mockVault), owner),
            usdc.allowance(owner, address(gateway))
        );
    }
}
