// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";
import { IYoVault } from "src/interfaces/IYoVault.sol";
import { Errors } from "src/libraries/Errors.sol";
import { YoVault } from "src/YoVault.sol";

import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract FulfillRedeemIntegrationConcreteTest is YoVaultBase_Test {
    uint256 internal constant AMOUNT = 100e6;
    /// @dev 10% oracle drop: AMOUNT shares are worth 90e6 at the current price.
    uint256 internal constant DROPPED_PRICE = 9e5;
    /// @dev 50% oracle rise: AMOUNT shares would be worth 150e6 at the current price.
    uint256 internal constant RAISED_PRICE = 15e5;
    uint256 internal constant WITHDRAW_FEE = 9e16;

    function setUp() public override {
        super.setUp();

        // Alice queues a redeem at parity; owner returns assets so fulfil can settle.
        _queueRedeem(users.alice, 1e6, AMOUNT);
        vm.prank(users.owner);
        usdc.transfer(address(yoVault), AMOUNT);
    }

    function _pending(address receiver) internal view returns (uint256 assets, uint256 shares) {
        return yoVault.pendingRedeemRequest(receiver);
    }

    function test_RevertWhen_TheCallerIsUnauthorized() external {
        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        yoVault.fulfillRedeem(users.alice, AMOUNT, false);
    }

    function test_RevertWhen_SharesIsZero() external {
        vm.prank(users.owner);
        vm.expectRevert(Errors.InvalidSharesAmount.selector);
        yoVault.fulfillRedeem(users.alice, 0, false);
    }

    function test_RevertWhen_TheReceiverHasNoPendingRequest() external {
        vm.prank(users.owner);
        vm.expectRevert(Errors.InvalidSharesAmount.selector);
        yoVault.fulfillRedeem(users.bob, 1, false);
    }

    function test_RevertWhen_SharesExceedsThePendingEntry() external {
        vm.prank(users.owner);
        vm.expectRevert(Errors.InvalidSharesAmount.selector);
        yoVault.fulfillRedeem(users.alice, AMOUNT + 1, false);
    }

    function test_RevertGiven_TheVaultIsPaused() external {
        vm.startPrank(users.owner);
        yoVault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        yoVault.fulfillRedeem(users.alice, AMOUNT, false);
        vm.stopPrank();
    }

    function test_WhenTheCallerIsAnAuthorizedOperator() external {
        _authorize(users.operator, address(yoVault), YoVault.fulfillRedeem.selector);
        uint256 aliceUsdcBefore = usdc.balanceOf(users.alice);

        vm.prank(users.operator);
        yoVault.fulfillRedeem(users.alice, AMOUNT, false);

        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + AMOUNT, "operator settled the request");
    }

    function test_WhenFulfilledWholeAtTheRequestPrice() external {
        // The price has dropped since the request; the reserved gross is paid regardless.
        _setOraclePrice(DROPPED_PRICE);
        uint256 aliceUsdcBefore = usdc.balanceOf(users.alice);

        vm.expectEmit(true, true, true, true, address(yoVault));
        emit IYoVault.RequestFulfilled(users.alice, AMOUNT, AMOUNT);
        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, AMOUNT, false);

        // it should burn the escrowed shares
        assertEq(yoVault.balanceOf(address(yoVault)), 0, "escrow burned");
        assertEq(yoVault.totalSupply(), 0, "supply burned");
        // it should pay the reserved gross
        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + AMOUNT, "reserved gross paid");
        // it should zero the pending entry
        (uint256 pendingAssets, uint256 pendingShares) = _pending(users.alice);
        assertEq(pendingAssets, 0, "pending assets zeroed");
        assertEq(pendingShares, 0, "pending shares zeroed");
        // it should release the reserved amount from totalPendingAssets
        assertEq(yoVault.totalPendingAssets(), 0, "reserved amount released");
    }

    function test_WhenFulfilledPartiallyAtTheRequestPrice() external {
        uint256 aliceUsdcBefore = usdc.balanceOf(users.alice);

        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, 40e6, false);

        // it should release the reserved amount proportionally
        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + 40e6, "proportional gross paid");
        assertEq(yoVault.totalPendingAssets(), 60e6, "proportional reservation released");
        // it should leave the remainder pending
        (uint256 pendingAssets, uint256 pendingShares) = _pending(users.alice);
        assertEq(pendingAssets, 60e6, "remaining assets pending");
        assertEq(pendingShares, 60e6, "remaining shares pending");
        assertEq(yoVault.balanceOf(address(yoVault)), 60e6, "remaining escrow");

        // it should settle the remainder exactly on the final fulfilment
        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, 60e6, false);
        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + AMOUNT, "remainder paid exactly");
        (pendingAssets, pendingShares) = _pending(users.alice);
        assertEq(pendingAssets, 0, "entry cleared");
        assertEq(pendingShares, 0, "entry cleared");
        assertEq(yoVault.totalPendingAssets(), 0, "nothing reserved");
    }

    function test_WhenThePriceDroppedAndFulfilledAtTheCurrentPrice() external {
        _setOraclePrice(DROPPED_PRICE);
        uint256 aliceUsdcBefore = usdc.balanceOf(users.alice);

        vm.expectEmit(true, true, true, true, address(yoVault));
        emit IYoVault.RequestFulfilled(users.alice, AMOUNT, 90e6);
        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, AMOUNT, true);

        // it should pay the shares at the current oracle price
        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + 90e6, "paid at current price");
        assertEq(usdc.balanceOf(address(yoVault)), 10e6, "haircut stays in the vault");
        // it should release the full reservation
        assertEq(yoVault.totalPendingAssets(), 0, "full reservation released");
    }

    function test_RevertWhen_ThePriceRoseAndFulfilledAtTheCurrentPrice() external {
        _setOraclePrice(RAISED_PRICE);

        vm.prank(users.owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.CurrentPriceAboveRequestPrice.selector, 150e6, AMOUNT));
        yoVault.fulfillRedeem(users.alice, AMOUNT, true);
    }

    function test_WhenThePriceIsUnchangedAndFulfilledPartiallyAtTheCurrentPrice() external {
        uint256 aliceUsdcBefore = usdc.balanceOf(users.alice);

        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, 40e6, true);

        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + 40e6, "pro-rata value at the unchanged price");
        assertEq(yoVault.totalPendingAssets(), 60e6, "proportional reservation released");
    }

    function test_WhenFulfilledAtTheCurrentPriceWithAFee() external {
        address feeCollector = makeAddr("FeeCollector");
        vm.startPrank(users.owner);
        yoVault.updateWithdrawFee(WITHDRAW_FEE);
        yoVault.updateFeeRecipient(feeCollector);
        vm.stopPrank();
        _setOraclePrice(DROPPED_PRICE);

        uint256 feeAmount = yoVault.exposed_feeOnTotal(90e6, WITHDRAW_FEE);
        uint256 aliceUsdcBefore = usdc.balanceOf(users.alice);

        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, AMOUNT, true);

        // it should pay the receiver net of the fee
        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + 90e6 - feeAmount, "net of fee at current price");
        // it should pay the fee to the fee recipient
        assertEq(usdc.balanceOf(feeCollector), feeAmount, "fee on the current-price gross");
    }

    function test_WhenAThirdPartyInflatedTheEntry() external {
        // Bob adds 1 share-wei to alice's entry while the vault is funded exactly for her request.
        vm.prank(users.bob);
        yoVault.deposit(1e6, users.bob);
        _moveAssetsFromVault(1e6);
        vm.prank(users.bob);
        yoVault.requestRedeem(1, users.alice, users.bob);
        (uint256 pendingAssets, uint256 pendingShares) = _pending(users.alice);
        assertEq(pendingShares, AMOUNT + 1, "entry inflated");

        // Settling the whole inflated entry needs more than the vault holds...
        vm.prank(users.owner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(yoVault), AMOUNT, AMOUNT + 1)
        );
        yoVault.fulfillRedeem(users.alice, AMOUNT + 1, false);

        // ...but the operator can settle exactly the legitimate portion and leave the dust pending.
        uint256 aliceUsdcBefore = usdc.balanceOf(users.alice);
        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, AMOUNT, false);

        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + AMOUNT, "legitimate portion paid");
        (pendingAssets, pendingShares) = _pending(users.alice);
        assertEq(pendingShares, 1, "dust shares remain pending");
        assertEq(pendingAssets, 1, "dust assets remain pending");
    }

    function test_WhenTwoRequestsAccumulatedOnTheReceiver() external {
        vm.prank(users.alice);
        yoVault.deposit(50e6, users.alice);
        _moveAssetsFromVault(50e6);
        vm.prank(users.alice);
        yoVault.requestRedeem(50e6, users.alice, users.alice);
        (uint256 pendingAssets, uint256 pendingShares) = _pending(users.alice);
        assertEq(pendingAssets, 150e6, "assets accumulated");
        assertEq(pendingShares, 150e6, "shares accumulated");
        vm.prank(users.owner);
        usdc.transfer(address(yoVault), 50e6);

        uint256 aliceUsdcBefore = usdc.balanceOf(users.alice);
        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, 150e6, false);

        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + 150e6, "combined entry paid");
        assertEq(yoVault.totalPendingAssets(), 0, "combined reservation released");
    }

    function test_WhenTheOraclePriceIsZero() external {
        _setOraclePrice(0);

        // it should refuse the current price
        vm.prank(users.owner);
        vm.expectRevert(Errors.InvalidPrice.selector);
        yoVault.fulfillRedeem(users.alice, AMOUNT, true);

        // it should settle at the request price without reading the oracle
        uint256 aliceUsdcBefore = usdc.balanceOf(users.alice);
        vm.prank(users.owner);
        yoVault.fulfillRedeem(users.alice, AMOUNT, false);
        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore + AMOUNT, "reserved gross paid with a dead oracle");
    }

    function test_RevertWhen_TheVaultHasInsufficientAssetBalance() external {
        _moveAssetsFromVault(AMOUNT);

        vm.prank(users.owner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(yoVault), 0, AMOUNT)
        );
        yoVault.fulfillRedeem(users.alice, AMOUNT, false);
    }
}
