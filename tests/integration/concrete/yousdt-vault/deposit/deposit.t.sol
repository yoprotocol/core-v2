// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { YoUSDTBase_Test } from "../YoUSDTBase.t.sol";

contract DepositIntegrationConcreteTest is YoUSDTBase_Test {
    using Math for uint256;

    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;

    function test_WhenDepositNoFees_RelaysNinetyFivePercent() external {
        uint256 expectedRelay = DEPOSIT_AMOUNT.mulDiv(RELAY_PERCENTAGE, DENOMINATOR, Math.Rounding.Floor);
        uint256 expectedKept = DEPOSIT_AMOUNT - expectedRelay;

        vm.prank(users.alice);
        vault.deposit(DEPOSIT_AMOUNT, users.alice);

        assertEq(usdc.balanceOf(YO_USD_ADDRESS), expectedRelay);
        assertEq(usdc.balanceOf(address(vault)), expectedKept);
        assertEq(vault.balanceOf(users.alice), DEPOSIT_AMOUNT);
    }

    function test_WhenDepositWithFee_RelaysNetAssetsAfterFee() external {
        // 1% deposit fee, recipient = bob.
        uint256 depositFee = 1e16;
        vm.startPrank(users.owner);
        vault.updateDepositFee(depositFee);
        vault.updateFeeRecipient(users.bob);
        vm.stopPrank();

        uint256 feeAmount = vault.previewDeposit(DEPOSIT_AMOUNT) > 0
            ? DEPOSIT_AMOUNT.mulDiv(depositFee, depositFee + DENOMINATOR, Math.Rounding.Ceil)
            : 0;
        uint256 netDeposit = DEPOSIT_AMOUNT - feeAmount;
        uint256 expectedRelay = netDeposit.mulDiv(RELAY_PERCENTAGE, DENOMINATOR, Math.Rounding.Floor);
        uint256 expectedKept = netDeposit - expectedRelay;

        vm.prank(users.alice);
        vault.deposit(DEPOSIT_AMOUNT, users.alice);

        assertEq(usdc.balanceOf(users.bob), feeAmount, "bob got fee");
        assertEq(usdc.balanceOf(YO_USD_ADDRESS), expectedRelay, "yoUSD got 95% of net");
        assertEq(usdc.balanceOf(address(vault)), expectedKept, "vault kept 5% of net");
    }

    function test_WhenDepositZero_NoRelay() external {
        vm.prank(users.alice);
        vault.deposit(0, users.alice);

        assertEq(usdc.balanceOf(YO_USD_ADDRESS), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }
}
