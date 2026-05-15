// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract MintIntegrationConcreteTest is YoVaultBase_Test {
    function test_WhenMintAtParityOracle_PullsAssetsOneToOne() external {
        uint256 shares = 100e6;
        assertEq(yoVault.balanceOf(users.alice), 0);

        vm.expectCall(address(usdc), abi.encodeCall(IERC20.transferFrom, (users.alice, address(yoVault), shares)));
        vm.prank(users.alice);
        yoVault.mint(shares, users.alice);

        assertEq(yoVault.balanceOf(users.alice), shares);
    }
}
