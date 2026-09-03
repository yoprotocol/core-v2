// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoUSDTBase_Test } from "../YoUSDTBase.t.sol";

contract FulfillRedeemYoUSDTIntegrationConcreteTest is YoUSDTBase_Test {
    uint256 internal constant AMOUNT = 100e6;

    function test_WhenFulfilledAtTheCurrentPriceAfterAHaircut() external {
        // The deposit relays 95% to yoUSD, so alice's full redemption must queue.
        vm.prank(users.alice);
        vault.deposit(AMOUNT, users.alice);
        vm.prank(users.alice);
        uint256 ret = vault.requestRedeem(AMOUNT, users.alice, users.alice);
        assertEq(ret, 0, "queued");

        // A 10% haircut on yoUSD, then liquidity returns.
        _setOraclePriceForYoUSD(9e5);
        usdc.mint(address(vault), AMOUNT);

        uint256 aliceUsdcBefore = usdc.balanceOf(users.alice);
        vm.prank(users.owner);
        vault.fulfillRedeem(users.alice, AMOUNT, true);

        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + 90e6, "priced against the yoUSD oracle");
        assertEq(vault.totalPendingAssets(), 0, "reservation released");
    }
}
