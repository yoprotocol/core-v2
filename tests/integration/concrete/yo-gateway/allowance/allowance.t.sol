// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Errors } from "src/libraries/Errors.sol";

import { YoGatewayBase_Test } from "../YoGatewayBase.t.sol";

contract AllowanceIntegrationConcreteTest is YoGatewayBase_Test {
    function test_GetShareAllowance_GivenAllowed_ReturnsVaultAllowance() external view {
        // Alice approved gateway type(uint256).max for shares in the base setUp.
        assertEq(
            gateway.getShareAllowance(address(mockVault), users.alice),
            mockVault.allowance(users.alice, address(gateway))
        );
    }

    function test_GetAssetAllowance_GivenAllowed_ReturnsAssetAllowance() external view {
        assertEq(
            gateway.getAssetAllowance(address(mockVault), users.alice),
            usdc.allowance(users.alice, address(gateway))
        );
    }

    function test_RevertWhen_GetShareAllowance_VaultNotAllowed() external {
        vm.expectRevert(Errors.Gateway__VaultNotAllowed.selector);
        gateway.getShareAllowance(address(0xDEAD), users.alice);
    }

    function test_RevertWhen_GetAssetAllowance_VaultNotAllowed() external {
        vm.expectRevert(Errors.Gateway__VaultNotAllowed.selector);
        gateway.getAssetAllowance(address(0xDEAD), users.alice);
    }
}
