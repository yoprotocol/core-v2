// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { YoUSDTBase_Test } from "../YoUSDTBase.t.sol";

contract OracleAssetIntegrationConcreteTest is YoUSDTBase_Test {
    using Math for uint256;

    function test_GivenOracleAtParity_TotalAssetsEqualsSupply() external {
        vm.prank(users.alice);
        vault.deposit(100e6, users.alice);

        uint256 supply = vault.totalSupply();
        uint256 expected = uint256(1e6).mulDiv(supply, 10 ** vault.decimals(), Math.Rounding.Floor);
        assertEq(vault.totalAssets(), expected);
    }

    function test_GivenOracleDoubles_TotalAssetsDoubles() external {
        vm.prank(users.alice);
        vault.deposit(100e6, users.alice);

        _setOraclePriceForYoUSD(2e6);

        uint256 supply = vault.totalSupply();
        uint256 expected = uint256(2e6).mulDiv(supply, 10 ** vault.decimals(), Math.Rounding.Floor);
        assertEq(vault.totalAssets(), expected);
    }
}
