// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { YoUSDTBase_Test } from "../../concrete/yousdt-vault/YoUSDTBase.t.sol";

contract Relay_YoUSDT_Integration_Fuzz_Test is YoUSDTBase_Test {
    using Math for uint256;

    /// @dev For any deposit, exactly 95% (floor-rounded) of the net post-fee assets reaches the
    ///      yoUSD relay destination, and the rest stays in the vault. Sum of {recipient, relay,
    ///      vault} equals the deposit amount.
    function testFuzz_Relay_ConservationAndPercentage(uint256 assets, uint256 fee) external {
        assets = bound(assets, 1e6, 500_000e6);
        fee = bound(fee, 0, 1e17 - 1); // [0, MAX_FEE)

        vm.startPrank(users.owner);
        vault.updateDepositFee(fee);
        vault.updateFeeRecipient(users.bob);
        vm.stopPrank();

        // _feeOnTotal: assets * fee / (fee + 1e18), ceiling rounded.
        uint256 feeAmount = fee == 0 ? 0 : assets.mulDiv(fee, fee + DENOMINATOR, Math.Rounding.Ceil);
        uint256 net = assets - feeAmount;
        uint256 expectedRelay = net.mulDiv(RELAY_PERCENTAGE, DENOMINATOR, Math.Rounding.Floor);
        uint256 expectedKept = net - expectedRelay;

        uint256 recipientBefore = usdc.balanceOf(users.bob);
        uint256 relayBefore = usdc.balanceOf(YO_USD_ADDRESS);

        vm.prank(users.alice);
        vault.deposit(assets, users.alice);

        uint256 recipientGot = usdc.balanceOf(users.bob) - recipientBefore;
        uint256 relayGot = usdc.balanceOf(YO_USD_ADDRESS) - relayBefore;
        uint256 vaultKept = usdc.balanceOf(address(vault));

        assertEq(recipientGot, feeAmount, "recipient share == fee");
        assertEq(relayGot, expectedRelay, "relay share == 95% of net (floor)");
        assertEq(vaultKept, expectedKept, "vault keeps the remainder");
        // Conservation: fee + relay + vaultKept == assets.
        assertEq(recipientGot + relayGot + vaultKept, assets, "conservation");
    }

    /// @dev With deposit fee = 0, the relay percentage applied to the gross amount equals 95% floor.
    function testFuzz_Relay_NoFee_NinetyFivePercent(uint256 assets) external {
        assets = bound(assets, 1e6, 500_000e6);

        uint256 expectedRelay = assets.mulDiv(RELAY_PERCENTAGE, DENOMINATOR, Math.Rounding.Floor);

        vm.prank(users.alice);
        vault.deposit(assets, users.alice);

        assertEq(usdc.balanceOf(YO_USD_ADDRESS), expectedRelay);
        assertEq(usdc.balanceOf(address(vault)), assets - expectedRelay);
    }
}
