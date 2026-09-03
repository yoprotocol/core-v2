// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";
import { IYoVault } from "src/interfaces/IYoVault.sol";
import { Errors } from "src/libraries/Errors.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract CancelRedeemIntegrationConcreteTest is YoVaultBase_Test {
    uint256 internal constant AMOUNT = 100e6;

    function setUp() public override {
        super.setUp();

        // Alice queues a redeem at parity.
        _queueRedeem(users.alice, 1e6, AMOUNT);
    }

    function test_RevertWhen_TheCallerIsUnauthorized() external {
        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        yoVault.cancelRedeem(users.alice);
    }

    function test_RevertWhen_TheReceiverHasNoPendingRequest() external {
        vm.prank(users.owner);
        vm.expectRevert(Errors.InvalidSharesAmount.selector);
        yoVault.cancelRedeem(users.bob);
    }

    function test_RevertGiven_TheVaultIsPaused() external {
        vm.startPrank(users.owner);
        yoVault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        yoVault.cancelRedeem(users.alice);
        vm.stopPrank();
    }

    function test_WhenTheReceiverHasAPendingRequest() external {
        vm.expectEmit(true, true, true, true, address(yoVault));
        emit IYoVault.RequestCancelled(users.alice, AMOUNT, AMOUNT);
        vm.prank(users.owner);
        yoVault.cancelRedeem(users.alice);

        // it should return all escrowed shares to the receiver
        assertEq(yoVault.balanceOf(users.alice), AMOUNT, "shares returned");
        assertEq(yoVault.balanceOf(address(yoVault)), 0, "escrow cleared");
        // it should zero the pending entry
        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(users.alice);
        assertEq(pendingAssets, 0, "pending assets zeroed");
        assertEq(pendingShares, 0, "pending shares zeroed");
        // it should release the reserved amount from totalPendingAssets
        assertEq(yoVault.totalPendingAssets(), 0, "reserved amount released");
    }

    function test_WhenTheEntryIsNotAtParity() external {
        // Bob deposits at twice the price: 100e6 assets buy 50e6 shares reserving 100e6 gross.
        _setOraclePrice(2e6);
        vm.prank(users.bob);
        yoVault.deposit(AMOUNT, users.bob);
        _moveAssetsFromVault(AMOUNT);
        vm.prank(users.bob);
        yoVault.requestRedeem(50e6, users.bob, users.bob);

        vm.expectEmit(true, true, true, true, address(yoVault));
        emit IYoVault.RequestCancelled(users.bob, 50e6, AMOUNT);
        vm.prank(users.owner);
        yoVault.cancelRedeem(users.bob);

        assertEq(yoVault.balanceOf(users.bob), 50e6, "shares returned");
        assertEq(yoVault.totalPendingAssets(), AMOUNT, "only alice's reservation remains");
    }

    function test_RevertWhen_CalledTwiceForTheSameReceiver() external {
        vm.startPrank(users.owner);
        yoVault.cancelRedeem(users.alice);

        vm.expectRevert(Errors.InvalidSharesAmount.selector);
        yoVault.cancelRedeem(users.alice);
        vm.stopPrank();
    }
}
