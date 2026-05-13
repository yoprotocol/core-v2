// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "src/interfaces/IMorpho.sol";
import { IYoMorphoAdapter } from "src/interfaces/IYoMorphoAdapter.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract WithdrawAll_Integration_Concrete_Test is Integration_Test {
    function _seedPosition(Id m, uint256 amount) internal {
        vm.prank(users.vault);
        morphoAdapter.supply(m, amount);
    }

    function test_RevertWhen_MarketNotAllowed() external whenCallerVault {
        Id m = defaults.MARKET_B();
        vm.expectRevert(abi.encodeWithSelector(IYoMorphoAdapter.MarketNotAllowed.selector, m));
        morphoAdapter.withdrawAll(m);
    }

    function test_RevertGiven_UnknownMarket() external whenMarketAllowed {
        Id m = Id.wrap(keccak256("UNKNOWN_MARKET"));
        _allowMarket(users.vault, m);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMorphoAdapter.UnknownMarket.selector, m));
        morphoAdapter.withdrawAll(m);
    }

    function test_RevertGiven_NoPosition() external whenCallerVault whenMarketAllowed {
        // Default market is allowlisted but the vault hasn't supplied yet.
        Id m = defaults.MARKET_A();
        vm.expectRevert(abi.encodeWithSelector(IYoMorphoAdapter.NoPosition.selector, m));
        morphoAdapter.withdrawAll(m);
    }

    function test_RevertGiven_NotAuthorized() external whenMarketAllowed {
        _seedPosition(defaults.MARKET_A(), defaults.SUPPLY_AMOUNT());

        vm.prank(users.vault);
        mockMorpho.setAuthorization(address(morphoAdapter), false);

        Id m = defaults.MARKET_A();
        vm.prank(users.vault);
        vm.expectRevert(bytes("not authorized"));
        morphoAdapter.withdrawAll(m);
    }

    function test_GivenAuthorizedAndPosition_DrainsToVault() external whenMarketAllowed {
        uint256 supplied = defaults.SUPPLY_AMOUNT();
        _seedPosition(defaults.MARKET_A(), supplied);

        Id m = defaults.MARKET_A();
        uint256 vaultBalBefore = usdc.balanceOf(users.vault);
        uint256 sharesBefore = mockMorpho.position(m, users.vault).supplyShares;
        assertGt(sharesBefore, 0);

        vm.prank(users.vault);
        (uint256 withdrawn, uint256 sharesBurned) = morphoAdapter.withdrawAll(m);

        assertEq(withdrawn, supplied, "assetsWithdrawn");
        assertEq(sharesBurned, sharesBefore, "sharesBurned");
        assertEq(usdc.balanceOf(users.vault), vaultBalBefore + supplied, "vault USDC restored");
        assertEq(mockMorpho.position(m, users.vault).supplyShares, 0, "vault position drained");
        assertZeroBalance(address(usdc), address(morphoAdapter));
    }
}
