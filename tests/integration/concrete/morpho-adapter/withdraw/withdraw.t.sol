// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "src/interfaces/IMorpho.sol";
import { IYoMorphoAdapter } from "src/interfaces/IYoMorphoAdapter.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract Withdraw_Integration_Concrete_Test is Integration_Test {
    /// @dev Funds the vault's Morpho position via the adapter so withdraw tests can run against
    ///      meaningful state.
    function _seedPosition(Id m, uint256 amount) internal {
        vm.prank(users.vault);
        morphoAdapter.supply(m, amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  REVERT BRANCHES
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_AssetsZero() external whenCallerVault {
        Id m = defaults.MARKET_A();
        vm.expectRevert(IYoMorphoAdapter.InvalidAmount.selector);
        morphoAdapter.withdraw(m, 0);
    }

    function test_RevertWhen_MarketNotAllowed() external whenCallerVault whenAmountNotZero {
        Id m = defaults.MARKET_B();
        uint256 amount = defaults.SUPPLY_AMOUNT();
        vm.expectRevert(abi.encodeWithSelector(IYoMorphoAdapter.MarketNotAllowed.selector, m));
        morphoAdapter.withdraw(m, amount);
    }

    function test_RevertGiven_UnknownMarket() external whenAmountNotZero whenMarketAllowed {
        Id m = Id.wrap(keccak256("UNKNOWN_MARKET"));
        _allowMarket(users.vault, m);

        uint256 amount = defaults.SUPPLY_AMOUNT();
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMorphoAdapter.UnknownMarket.selector, m));
        morphoAdapter.withdraw(m, amount);
    }

    function test_RevertGiven_NotAuthorized() external whenAmountNotZero whenMarketAllowed {
        // Seed a position first (auth still in place from setUp), then revoke auth, then withdraw.
        _seedPosition(defaults.MARKET_A(), defaults.SUPPLY_AMOUNT());

        vm.prank(users.vault);
        mockMorpho.setAuthorization(address(morphoAdapter), false);

        Id m = defaults.MARKET_A();
        uint256 amount = defaults.SUPPLY_AMOUNT() / 2;
        vm.prank(users.vault);
        vm.expectRevert(bytes("not authorized"));
        morphoAdapter.withdraw(m, amount);
    }

    function test_RevertGiven_AssetsExceedsPosition() external whenAmountNotZero whenMarketAllowed {
        _seedPosition(defaults.MARKET_A(), defaults.SUPPLY_AMOUNT());

        Id m = defaults.MARKET_A();
        uint256 tooMuch = defaults.SUPPLY_AMOUNT() * 2;
        vm.prank(users.vault);
        vm.expectRevert(bytes("insufficient"));
        morphoAdapter.withdraw(m, tooMuch);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  HAPPY-PATH
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenAssetsWithinPosition_TransfersAndReturns() external whenAmountNotZero whenMarketAllowed {
        uint256 supplied = defaults.SUPPLY_AMOUNT();
        _seedPosition(defaults.MARKET_A(), supplied);

        Id m = defaults.MARKET_A();
        uint256 toWithdraw = supplied / 2;
        uint256 vaultBalBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        (uint256 withdrawn, uint256 sharesBurned) = morphoAdapter.withdraw(m, toWithdraw);

        assertEq(withdrawn, toWithdraw, "assetsWithdrawn");
        assertGt(sharesBurned, 0, "sharesBurned");
        assertEq(usdc.balanceOf(users.vault), vaultBalBefore + toWithdraw, "vault USDC delta");
        assertEq(mockMorpho.position(m, users.vault).supplyShares, supplied - toWithdraw, "remaining shares");

        // Custody invariant — adapter never sees the loan token mid-withdraw on the happy path.
        assertZeroBalance(address(usdc), address(morphoAdapter));
    }
}
