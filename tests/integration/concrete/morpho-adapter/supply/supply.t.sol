// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { Id } from "src/interfaces/IMorpho.sol";
import { IYoMorphoAdapter } from "src/interfaces/IYoMorphoAdapter.sol";

import { MockReentrantERC20 } from "../../../../mocks/MockReentrantERC20.sol";
import { Integration_Test } from "../../../Integration.t.sol";

contract SupplyIntegrationConcreteTest is Integration_Test {
    /*//////////////////////////////////////////////////////////////////////////
                                  REVERT BRANCHES
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_AssetsZero() external whenCallerVault {
        // Compute call args BEFORE `vm.expectRevert` — a view call to `defaults` would otherwise
        // consume the expectation and the test would falsely report no revert.
        Id m = defaults.MARKET_A();
        vm.expectRevert(IYoMorphoAdapter.InvalidAmount.selector);
        morphoAdapter.supply(m, 0);
    }

    function test_RevertWhen_MarketNotAllowed() external whenCallerVault whenAmountNotZero {
        Id m = defaults.MARKET_B();
        uint256 amount = defaults.SUPPLY_AMOUNT();
        vm.expectRevert(abi.encodeWithSelector(IYoMorphoAdapter.MarketNotAllowed.selector, m));
        morphoAdapter.supply(m, amount);
    }

    function test_RevertGiven_UnknownMarket() external whenAmountNotZero whenMarketAllowed {
        // Allowlist a market id that wasn't registered with `MockMorpho.setMarketParams`.
        // (`whenCallerVault` is omitted because `_allowMarket` pranks as owner first.)
        Id m = Id.wrap(keccak256("UNKNOWN_MARKET"));
        _allowMarket(users.vault, m);

        uint256 amount = defaults.SUPPLY_AMOUNT();
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoMorphoAdapter.UnknownMarket.selector, m));
        morphoAdapter.supply(m, amount);
    }

    function test_RevertGiven_VaultHasNotApprovedAdapter() external whenAmountNotZero whenMarketAllowed {
        // Revoke the default approval that Integration_Test.setUp() granted.
        vm.prank(users.vault);
        usdc.approve(address(morphoAdapter), 0);

        Id m = defaults.MARKET_A();
        uint256 amount = defaults.SUPPLY_AMOUNT();
        vm.prank(users.vault);
        // OZ ERC20 emits `ERC20InsufficientAllowance(spender, current, needed)`. Use a generic match.
        vm.expectRevert();
        morphoAdapter.supply(m, amount);
    }

    function test_RevertWhen_Reentered() external whenAmountNotZero whenMarketAllowed {
        // Stand up a reentrant token, register it as a Morpho market's loan token, allowlist that
        // market for the vault, fund + approve, then arm the token to call back into the adapter.
        MockReentrantERC20 rent = new MockReentrantERC20();
        Id m = Id.wrap(keccak256("REENTRANT_MARKET"));
        _setupMarket(m, address(rent));
        _allowMarket(users.vault, m);

        rent.mint(users.vault, 1000e6);
        vm.prank(users.vault);
        rent.approve(address(morphoAdapter), type(uint256).max);

        // Reentry payload: outer adapter is locked, so any `nonReentrant` adapter call from inside
        // `transferFrom` should revert with `ReentrancyGuardReentrantCall`.
        bytes memory payload = abi.encodeCall(IYoMorphoAdapter.supply, (m, 1));
        rent.arm(address(morphoAdapter), payload);

        vm.prank(users.vault);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        morphoAdapter.supply(m, 100e6);
    }

    function test_RevertGiven_NoShareDelta() external whenCallerVault whenAmountNotZero whenMarketAllowed {
        mockMorpho.setSkipShareCredit(true);

        Id m = defaults.MARKET_A();
        uint256 amount = defaults.SUPPLY_AMOUNT();
        vm.expectRevert(IYoMorphoAdapter.NoShareDelta.selector);
        morphoAdapter.supply(m, amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  HAPPY-PATH
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenPositiveShareDelta_PullsAndSettles()
        external
        whenCallerVault
        whenAmountNotZero
        whenMarketAllowed
    {
        Id m = defaults.MARKET_A();
        uint256 amount = defaults.SUPPLY_AMOUNT();
        uint256 vaultBalBefore = usdc.balanceOf(users.vault);

        (uint256 supplied, uint256 sharesSupplied) = morphoAdapter.supply(m, amount);

        // Returned values are non-zero.
        assertEq(supplied, amount, "assetsSupplied");
        assertGt(sharesSupplied, 0, "sharesSupplied");

        // Vault balance dropped by exactly amount.
        assertEq(usdc.balanceOf(users.vault), vaultBalBefore - amount, "vault USDC delta");

        // Position recorded against the vault, not the adapter.
        assertGt(mockMorpho.position(m, users.vault).supplyShares, 0, "vault supply shares");
        assertEq(mockMorpho.position(m, address(morphoAdapter)).supplyShares, 0, "adapter must own no position");

        // Custody invariants: adapter ends clean.
        assertZeroBalance(address(usdc), address(morphoAdapter));
        assertZeroAllowance(address(usdc), address(morphoAdapter), address(mockMorpho));
    }

    function test_EmitsAdapterAction() external whenCallerVault whenAmountNotZero whenMarketAllowed {
        Id m = defaults.MARKET_A();
        uint256 amount = defaults.SUPPLY_AMOUNT();
        vm.expectEmit(true, true, true, true, address(morphoAdapter));
        emit YoAdapterBase.AdapterAction(
            users.vault,
            address(mockMorpho),
            address(usdc),
            YoAdapterBase.AdapterDirection.Deposit,
            amount
        );
        morphoAdapter.supply(m, amount);
    }
}
