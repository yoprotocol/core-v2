// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoTokenBase_Test } from "../../concrete/yo-token/YoTokenBase.t.sol";

contract TransferFrom_YoToken_Integration_Fuzz_Test is YoTokenBase_Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @dev Owner can transferFrom themselves to any receiver. Owner balance shrinks by exactly
    ///      `amount`, receiver grows by exactly `amount`, supply unchanged.
    function testFuzz_TransferFrom_Owner_PreservesSupply(uint256 amount) external {
        amount = bound(amount, 0, INITIAL_SUPPLY);

        vm.startPrank(users.owner);
        token.approve(users.owner, amount);
        token.transferFrom(users.owner, users.alice, amount);
        vm.stopPrank();

        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(users.owner), INITIAL_SUPPLY - amount);
        assertEq(token.balanceOf(users.alice), amount);
    }

    /// @dev `transferFrom` consumes allowance: allowance after equals (allowance before - amount).
    ///      Holds even when the spender is also the granted `_update` caller.
    function testFuzz_TransferFrom_DecrementsAllowance(uint256 grant, uint256 amount) external {
        grant = bound(grant, 0, INITIAL_SUPPLY);
        amount = bound(amount, 0, grant);

        // Grant bob both an ERC-20 allowance and the transferFrom selector under auth.
        vm.prank(users.owner);
        token.approve(users.bob, grant);
        _grantSelector(users.bob, IERC20.transferFrom.selector);

        vm.prank(users.bob);
        token.transferFrom(users.owner, users.alice, amount);

        assertEq(
            token.allowance(users.owner, users.bob),
            grant - amount,
            "allowance decremented exactly"
        );
        assertEq(token.balanceOf(users.alice), amount);
    }

    /// @dev `transferFrom` with `amount > allowance` reverts and leaves state untouched.
    function testFuzz_TransferFrom_RevertsAboveAllowance(uint256 grant, uint256 amount) external {
        grant = bound(grant, 0, INITIAL_SUPPLY - 1);
        amount = bound(amount, grant + 1, INITIAL_SUPPLY);

        vm.prank(users.owner);
        token.approve(users.bob, grant);
        _grantSelector(users.bob, IERC20.transferFrom.selector);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(users.bob);
        vm.expectRevert();
        token.transferFrom(users.owner, users.alice, amount);

        assertEq(token.totalSupply(), supplyBefore, "no supply change");
        assertEq(token.allowance(users.owner, users.bob), grant, "allowance unchanged");
    }
}
