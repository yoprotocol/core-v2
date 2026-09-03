// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoVaultBase_Test } from "../integration/concrete/yo-vault/YoVaultBase.t.sol";
import { RedeemAccountingHandler } from "./handlers/RedeemAccountingHandler.sol";

/// @notice Accounting invariants of partial fulfilment under random interleavings of queued
///         requests (any owner toward any receiver), partial fulfilments in both price modes,
///         cancels, oracle moves and fee changes. Every entry starts queued, so settlement actions
///         have work from the first call; the handler's `vm.assume` discards idle calls instead of
///         spending campaign depth on them.
contract RedeemAccountingInvariantTest is YoVaultBase_Test {
    RedeemAccountingHandler internal handler;
    address[3] internal actors;

    function setUp() public override {
        super.setUp();

        address feeCollector = makeAddr("FeeCollector");
        vm.prank(users.owner);
        yoVault.updateFeeRecipient(feeCollector);

        actors = [address(users.alice), address(users.bob), address(users.eve)];
        handler = new RedeemAccountingHandler(yoVault, usdc, users.owner, feeCollector, actors);
        vm.label(address(handler), "RedeemAccountingHandler");

        // Seed one queued entry per actor so fulfil/cancel are live from call one.
        for (uint256 i; i < actors.length; ++i) {
            handler.queue(i, i, 1000e6 * (i + 1));
        }

        targetContract(address(handler));
        excludeSender(address(yoVault));
        excludeSender(address(usdc));
    }

    function _sumEntries() internal view returns (uint256 assets, uint256 shares) {
        for (uint256 i; i < actors.length; ++i) {
            (uint256 a, uint256 s) = yoVault.pendingRedeemRequest(actors[i]);
            assets += a;
            shares += s;
        }
    }

    /// @dev The reservation ledger equals the sum of every receiver's reserved assets.
    function invariant_TotalPendingAssetsEqualsSumOfEntries() external view {
        (uint256 assets,) = _sumEntries();
        assertEq(yoVault.totalPendingAssets(), assets, "ledger != sum of entries");
    }

    /// @dev The ledger also equals the independent model: reservations created minus released.
    function invariant_LedgerMatchesGhostModel() external view {
        assertEq(yoVault.totalPendingAssets(), handler.ghostReserved() - handler.ghostReleased(), "ledger != model");
    }

    /// @dev The vault holds exactly the shares still pending — every partial burns precisely its slice.
    function invariant_EscrowEqualsSumOfPendingShares() external view {
        (, uint256 shares) = _sumEntries();
        assertEq(yoVault.balanceOf(address(yoVault)), shares, "escrow != sum of pending shares");
    }

    /// @dev An entry with no shares left carries no reservation — nothing is ever orphaned.
    function invariant_NoSharesImpliesNoAssets() external view {
        for (uint256 i; i < actors.length; ++i) {
            (uint256 assets, uint256 shares) = yoVault.pendingRedeemRequest(actors[i]);
            if (shares == 0) assertEq(assets, 0, "orphaned reservation");
        }
    }

    /// @dev Request-price fulfilments pay exactly what they release; current-price fulfilments
    ///      never pay more than they release.
    function invariant_PayoutsMatchReleases() external view {
        for (uint256 i; i < actors.length; ++i) {
            address r = actors[i];
            assertEq(
                handler.paidAtRequestPrice(r), handler.releasedAtRequestPrice(r), "request-price payout != release"
            );
            assertLe(handler.paidAtCurrentPrice(r), handler.releasedAtCurrentPrice(r), "current-price payout > release");
        }
    }
}
