// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";

import { Integration_Test } from "../../Integration.t.sol";

/// @notice Rescue covers `IERC20` and ETH dust on every adapter via the shared {YoAdapterBase}.
///         We exercise it through `morphoAdapter` because the logic lives in the base; each child
///         adapter inherits identically. If you suspect divergence, run the same suite against
///         `swapAdapter`, `yieldAdapter`, and `lidoAdapter` — they share storage layout and
///         function-selector set for these two entry points.
contract Rescue_AdapterBase_Integration_Fuzz_Test is Integration_Test {
    YoAdapterBase internal adapter;

    function setUp() public override {
        super.setUp();
        adapter = YoAdapterBase(payable(address(morphoAdapter)));
    }

    /// @dev A registered vault can rescue any token balance from the adapter to itself.
    function testFuzz_Rescue_ByRegisteredVault_SweepsToCaller(uint256 dust) external {
        dust = bound(dust, 1, type(uint128).max);
        usdc.mint(address(adapter), dust);

        uint256 vaultBalBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 swept = adapter.rescue(usdc);

        assertEq(swept, dust, "return == sweep amount");
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter cleaned");
        assertEq(usdc.balanceOf(users.vault), vaultBalBefore + dust, "vault received");
    }

    /// @dev Rescue from a non-registered caller reverts with `CallerNotYoVault(caller)`.
    function testFuzz_Rescue_ByNonRegisteredCaller_Reverts(address caller, uint256 dust) external {
        vm.assume(caller != users.vault && caller != address(0));
        dust = bound(dust, 0, type(uint128).max);

        if (dust > 0) {
            usdc.mint(address(adapter), dust);
        }

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(YoAdapterBase.CallerNotYoVault.selector, caller));
        adapter.rescue(usdc);

        // Adapter state unchanged.
        assertEq(usdc.balanceOf(address(adapter)), dust, "dust still parked");
    }

    /// @dev `rescueETH` mirrors `rescue` for ETH balances.
    function testFuzz_RescueETH_ByRegisteredVault_SweepsToCaller(uint256 dust) external {
        dust = bound(dust, 1, 1000 ether);
        vm.deal(address(adapter), dust);

        uint256 vaultBalBefore = users.vault.balance;

        vm.prank(users.vault);
        uint256 swept = adapter.rescueETH();

        assertEq(swept, dust);
        assertEq(address(adapter).balance, 0);
        assertEq(users.vault.balance, vaultBalBefore + dust);
    }

    function testFuzz_RescueETH_ByNonRegisteredCaller_Reverts(address caller) external {
        vm.assume(caller != users.vault && caller != address(0));
        vm.deal(address(adapter), 1 ether);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(YoAdapterBase.CallerNotYoVault.selector, caller));
        adapter.rescueETH();

        assertEq(address(adapter).balance, 1 ether);
    }

    /// @dev After a vault is removed from the registry it can no longer rescue.
    function testFuzz_Rescue_RevokedVault_LosesRescueRights(uint256 dust) external {
        dust = bound(dust, 1, type(uint128).max);
        usdc.mint(address(adapter), dust);

        // De-list the vault.
        yoRegistry.setVault(users.vault, false);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(YoAdapterBase.CallerNotYoVault.selector, users.vault));
        adapter.rescue(usdc);
    }

    /// @dev Rescue on an empty adapter succeeds with `amount == 0` (event still emitted).
    function testFuzz_Rescue_ZeroBalance_Succeeds() external {
        vm.prank(users.vault);
        uint256 swept = adapter.rescue(usdc);
        assertEq(swept, 0);
    }
}
