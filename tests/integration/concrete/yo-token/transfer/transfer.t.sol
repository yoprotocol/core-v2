// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";

import { YoTokenBase_Test } from "../YoTokenBase.t.sol";

contract TransferIntegrationConcreteTest is YoTokenBase_Test {
    uint256 internal constant AMOUNT = 100e18;

    function test_WhenOwnerTransfers_Succeeds() external {
        vm.prank(users.owner);
        token.transfer(users.bob, AMOUNT);
        assertEq(token.balanceOf(users.bob), AMOUNT);
    }

    function test_RevertWhen_NonOwnerWithoutGrant() external {
        vm.prank(users.owner);
        token.transfer(users.bob, AMOUNT);

        vm.prank(users.bob);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        token.transfer(users.alice, 1e18);
    }

    function test_WhenAuthorityGrantsSelector_AllowsCallerToTransfer() external {
        vm.prank(users.owner);
        token.transfer(users.bob, AMOUNT);

        _grantSelector(users.bob, IERC20.transfer.selector);

        vm.prank(users.bob);
        token.transfer(users.alice, 5e18);
        assertEq(token.balanceOf(users.bob), AMOUNT - 5e18);
        assertEq(token.balanceOf(users.alice), 5e18);
    }

    function test_WhenOwnerUsesTransferFrom_Succeeds() external {
        vm.prank(users.owner);
        token.approve(users.owner, AMOUNT);

        vm.prank(users.owner);
        token.transferFrom(users.owner, users.bob, AMOUNT);
        assertEq(token.balanceOf(users.bob), AMOUNT);
    }

    function test_RevertWhen_NonOwnerTransferFromWithoutGrant() external {
        vm.prank(users.owner);
        token.approve(users.bob, AMOUNT);

        vm.prank(users.bob);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        token.transferFrom(users.owner, users.alice, 1e18);
    }
}
