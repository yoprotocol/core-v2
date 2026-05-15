// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoGateway } from "src/interfaces/IYoGateway.sol";
import { Errors } from "src/libraries/Errors.sol";

import { YoGatewayBase_Test } from "../YoGatewayBase.t.sol";

contract RedeemIntegrationConcreteTest is YoGatewayBase_Test {
    uint256 internal constant ASSETS = 1000e6;
    uint32 internal constant PARTNER_ID = 42;

    function _seedShares() internal returns (uint256 shares) {
        vm.prank(users.alice);
        shares = gateway.deposit(address(mockVault), ASSETS, 1, users.alice, PARTNER_ID);
    }

    function test_WhenInstantRedeem_Succeeds() external {
        uint256 shares = _seedShares();
        uint256 callerBefore = usdc.balanceOf(users.alice);

        vm.prank(users.alice);
        uint256 ret = gateway.redeem(address(mockVault), shares, 1, users.alice, PARTNER_ID);

        assertGt(ret, 0, "instant path returns assets");
        assertEq(mockVault.balanceOf(users.alice), 0);
        assertEq(usdc.balanceOf(users.alice), callerBefore + ret);
    }

    function test_WhenEmitsRedeemEvent() external {
        uint256 shares = _seedShares();
        uint256 expected = mockVault.previewRedeem(shares);

        vm.expectEmit(true, true, true, true, address(gateway));
        emit IYoGateway.YoGatewayRedeem(PARTNER_ID, address(mockVault), users.alice, shares, expected, true);

        vm.prank(users.alice);
        gateway.redeem(address(mockVault), shares, 1, users.alice, PARTNER_ID);
    }

    function test_RevertWhen_ZeroShares() external {
        vm.prank(users.alice);
        vm.expectRevert(Errors.Gateway__ZeroAmount.selector);
        gateway.redeem(address(mockVault), 0, 1, users.alice, PARTNER_ID);
    }

    function test_RevertWhen_ZeroReceiver() external {
        uint256 shares = _seedShares();
        vm.prank(users.alice);
        vm.expectRevert(Errors.Gateway__ZeroReceiver.selector);
        gateway.redeem(address(mockVault), shares, 1, address(0), PARTNER_ID);
    }

    function test_RevertWhen_VaultNotAllowed() external {
        vm.prank(users.alice);
        vm.expectRevert(Errors.Gateway__VaultNotAllowed.selector);
        gateway.redeem(address(0xDEAD), 1, 1, users.alice, PARTNER_ID);
    }

    function test_RevertWhen_BelowMinAssetsOut() external {
        uint256 shares = _seedShares();
        uint256 expected = mockVault.previewRedeem(shares);

        vm.prank(users.alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.Gateway__InsufficientAssetsOut.selector, expected, expected + 1));
        gateway.redeem(address(mockVault), shares, expected + 1, users.alice, PARTNER_ID);
    }
}
