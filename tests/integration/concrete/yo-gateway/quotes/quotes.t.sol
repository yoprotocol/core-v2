// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Errors } from "src/libraries/Errors.sol";

import { YoGatewayBase_Test } from "../YoGatewayBase.t.sol";

contract QuotesIntegrationConcreteTest is YoGatewayBase_Test {
    uint256 internal constant AMOUNT = 100e6;

    function test_QuotesMirrorVault() external view {
        assertEq(
            gateway.quoteConvertToShares(address(mockVault), AMOUNT),
            mockVault.convertToShares(AMOUNT)
        );
        assertEq(
            gateway.quoteConvertToAssets(address(mockVault), AMOUNT),
            mockVault.convertToAssets(AMOUNT)
        );
        assertEq(
            gateway.quotePreviewDeposit(address(mockVault), AMOUNT),
            mockVault.previewDeposit(AMOUNT)
        );
        assertEq(
            gateway.quotePreviewRedeem(address(mockVault), AMOUNT),
            mockVault.previewRedeem(AMOUNT)
        );
        assertEq(
            gateway.quotePreviewWithdraw(address(mockVault), AMOUNT),
            mockVault.previewWithdraw(AMOUNT)
        );
    }

    function test_RevertWhen_VaultNotAllowed_OnEveryQuote() external {
        address bad = address(0xDEAD);

        vm.expectRevert(Errors.Gateway__VaultNotAllowed.selector);
        gateway.quoteConvertToShares(bad, AMOUNT);

        vm.expectRevert(Errors.Gateway__VaultNotAllowed.selector);
        gateway.quoteConvertToAssets(bad, AMOUNT);

        vm.expectRevert(Errors.Gateway__VaultNotAllowed.selector);
        gateway.quotePreviewDeposit(bad, AMOUNT);

        vm.expectRevert(Errors.Gateway__VaultNotAllowed.selector);
        gateway.quotePreviewRedeem(bad, AMOUNT);

        vm.expectRevert(Errors.Gateway__VaultNotAllowed.selector);
        gateway.quotePreviewWithdraw(bad, AMOUNT);
    }
}
