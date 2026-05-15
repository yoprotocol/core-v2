// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract TotalAssetsIntegrationConcreteTest is YoVaultBase_Test {
    using Math for uint256;

    function test_GivenZeroSupply_ReturnsZero() external view {
        assertEq(yoVault.totalAssets(), 0);
    }

    function test_GivenSupplyAtParity_ReturnsSupply() external {
        uint256 amount = 100e6;
        vm.prank(users.alice);
        yoVault.deposit(amount, users.alice);

        uint256 supply = yoVault.totalSupply();
        uint256 expected = uint256(1e6).mulDiv(supply, 10 ** yoVault.decimals(), Math.Rounding.Floor);
        assertEq(yoVault.totalAssets(), expected);
    }

    function test_GivenPriceDoubles_ScalesTotalAssets() external {
        uint256 amount = 100e6;
        vm.prank(users.alice);
        yoVault.deposit(amount, users.alice);

        _setOraclePrice(2e6);

        uint256 supply = yoVault.totalSupply();
        uint256 expected = uint256(2e6).mulDiv(supply, 10 ** yoVault.decimals(), Math.Rounding.Floor);
        assertEq(yoVault.totalAssets(), expected);
    }
}
