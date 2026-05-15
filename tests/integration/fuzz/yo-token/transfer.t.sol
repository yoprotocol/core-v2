// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoTokenBase_Test } from "../../concrete/yo-token/YoTokenBase.t.sol";

contract Transfer_YoToken_Integration_Fuzz_Test is YoTokenBase_Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @dev Total supply is constant under any non-burn transfer sequence.
    function testFuzz_Transfer_PreservesSupply(uint256 amount) external {
        amount = bound(amount, 0, INITIAL_SUPPLY);

        vm.prank(users.owner);
        token.transfer(users.alice, amount);

        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(users.owner) + token.balanceOf(users.alice), INITIAL_SUPPLY);
    }

    /// @dev burn(x) reduces supply by exactly x and shrinks the burner's balance by exactly x.
    function testFuzz_Burn_ReducesSupplyExactly(uint256 amount) external {
        amount = bound(amount, 0, INITIAL_SUPPLY);

        uint256 supplyBefore = token.totalSupply();
        uint256 balBefore = token.balanceOf(users.owner);

        vm.prank(users.owner);
        token.burn(amount);

        assertEq(token.totalSupply(), supplyBefore - amount);
        assertEq(token.balanceOf(users.owner), balBefore - amount);
    }

    /// @dev With an explicit grant, a non-owner can transfer up to their balance.
    function testFuzz_Transfer_GrantedCaller_Succeeds(uint256 seed, uint256 amount) external {
        // Give bob some balance, then grant him transfer rights.
        uint256 seedBounded = bound(seed, 1, INITIAL_SUPPLY);
        vm.prank(users.owner);
        token.transfer(users.bob, seedBounded);

        _grantSelector(users.bob, IERC20.transfer.selector);

        amount = bound(amount, 0, seedBounded);
        vm.prank(users.bob);
        token.transfer(users.alice, amount);

        assertEq(token.balanceOf(users.bob), seedBounded - amount);
        assertEq(token.balanceOf(users.alice), amount);
    }
}
