// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { CommonBase } from "forge-std/src/Base.sol";
import { StdUtils } from "forge-std/src/StdUtils.sol";

import { IYoOracle } from "src/interfaces/IYoOracle.sol";
import { Errors } from "src/libraries/Errors.sol";
import { YoVault } from "src/YoVault.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { ProRata } from "../../utils/ProRata.sol";

/// @notice Bounded-action handler for the redemption-accounting invariant suite. Every action
///         either discards its call with `vm.assume` when it has nothing to do, or asserts the
///         exact outcome against an independent model: reservations are modelled with the oracle
///         conversion at request time, releases with {ProRata}, and every ledger and entry delta
///         is checked against that model in the same call. Reverts are expected only from the
///         two settlement guards, and each is asserted to fire exactly when the model says so.
contract RedeemAccountingHandler is CommonBase, StdUtils {
    error GuardDidNotFire();
    error UnexpectedRevert(bytes4 selector);
    error PayoutMismatch(uint256 paid, uint256 expected);
    error ReservationMismatch(uint256 actual, uint256 expected);
    error ReleaseMismatch(uint256 actual, uint256 expected);

    YoVault internal immutable VAULT;
    MockERC20 internal immutable TOKEN;
    address internal immutable OWNER;
    address internal immutable FEE_RECIPIENT;
    address[3] internal actors;

    /// @dev Ghost ledger: reservations created minus reservations released, per the model.
    uint256 public ghostReserved;
    uint256 public ghostReleased;
    /// @dev Ghost payouts per receiver, split by price mode (gross, fee included).
    mapping(address receiver => uint256 assets) public releasedAtRequestPrice;
    mapping(address receiver => uint256 assets) public paidAtRequestPrice;
    mapping(address receiver => uint256 assets) public releasedAtCurrentPrice;
    mapping(address receiver => uint256 assets) public paidAtCurrentPrice;
    /// @dev How often each guard fired — reported so a campaign that never reached them is visible.
    uint256 public priceGuardTrips;
    uint256 public zeroGrossRefusals;

    constructor(YoVault _vault, MockERC20 _token, address _owner, address _feeRecipient, address[3] memory _actors) {
        VAULT = _vault;
        TOKEN = _token;
        OWNER = _owner;
        FEE_RECIPIENT = _feeRecipient;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    /// @notice Deposit for `owner`, drain the vault so the request must queue, and queue every
    ///         minted share toward `receiver` (any actor — third-party appends included).
    function queue(uint256 ownerSeed, uint256 receiverSeed, uint256 assets) external {
        address owner = _actor(ownerSeed);
        address receiver = _actor(receiverSeed);
        assets = bound(assets, 2, 1_000_000e6);
        TOKEN.mint(owner, assets);
        vm.startPrank(owner);
        TOKEN.approve(address(VAULT), assets);
        uint256 shares = VAULT.deposit(assets, owner);
        vm.stopPrank();

        uint256 balance = TOKEN.balanceOf(address(VAULT));
        vm.prank(address(VAULT));
        TOKEN.transfer(OWNER, balance);

        uint256 expectedReserved = VAULT.convertToAssets(shares);
        (uint256 entryBefore,) = VAULT.pendingRedeemRequest(receiver);
        uint256 ledgerBefore = VAULT.totalPendingAssets();

        vm.prank(owner);
        VAULT.requestRedeem(shares, receiver, owner);

        (uint256 entryAfter,) = VAULT.pendingRedeemRequest(receiver);
        if (entryAfter - entryBefore != expectedReserved) {
            revert ReservationMismatch(entryAfter - entryBefore, expectedReserved);
        }
        if (VAULT.totalPendingAssets() - ledgerBefore != expectedReserved) {
            revert ReservationMismatch(VAULT.totalPendingAssets() - ledgerBefore, expectedReserved);
        }
        // solhint-disable-next-line reentrancy
        ghostReserved += expectedReserved;
    }

    /// @notice Fulfil a random slice of a receiver's entry in either price mode.
    function fulfil(uint256 receiverSeed, uint256 sharesSeed, bool atCurrentPrice) external {
        address receiver = _actor(receiverSeed);
        (uint256 pendingAssets, uint256 pendingShares) = VAULT.pendingRedeemRequest(receiver);
        vm.assume(pendingShares != 0);
        uint256 shares = bound(sharesSeed, 1, pendingShares);
        uint256 released = ProRata.slice(pendingAssets, shares, pendingShares);

        uint256 expectedPaid = released;
        if (atCurrentPrice) {
            uint256 currentValue = VAULT.convertToAssets(pendingShares);
            if (currentValue > pendingAssets) {
                _expectRefused(receiver, shares, true, Errors.CurrentPriceAboveRequestPrice.selector);
                ++priceGuardTrips;
                return;
            }
            expectedPaid = ProRata.slice(currentValue, shares, pendingShares);
        }
        if (expectedPaid == 0) {
            _expectRefused(receiver, shares, atCurrentPrice, Errors.InvalidAssetsAmount.selector);
            ++zeroGrossRefusals;
            return;
        }

        // Fund the payout so liquidity never masks an accounting error.
        TOKEN.mint(address(VAULT), expectedPaid);
        uint256 receiverBefore = TOKEN.balanceOf(receiver);
        uint256 feeBefore = TOKEN.balanceOf(FEE_RECIPIENT);
        uint256 ledgerBefore = VAULT.totalPendingAssets();

        vm.prank(OWNER);
        VAULT.fulfillRedeem(receiver, shares, atCurrentPrice);

        // Gross paid = receiver net + fee taken; both against the model.
        uint256 paid = (TOKEN.balanceOf(receiver) - receiverBefore) + (TOKEN.balanceOf(FEE_RECIPIENT) - feeBefore);
        if (paid != expectedPaid) revert PayoutMismatch(paid, expectedPaid);
        uint256 ledgerDelta = ledgerBefore - VAULT.totalPendingAssets();
        if (ledgerDelta != released) revert ReleaseMismatch(ledgerDelta, released);
        (uint256 entryAfter,) = VAULT.pendingRedeemRequest(receiver);
        if (pendingAssets - entryAfter != released) revert ReleaseMismatch(pendingAssets - entryAfter, released);

        ghostReleased += released;
        if (atCurrentPrice) {
            releasedAtCurrentPrice[receiver] += released;
            paidAtCurrentPrice[receiver] += paid;
        } else {
            releasedAtRequestPrice[receiver] += released;
            paidAtRequestPrice[receiver] += paid;
        }
    }

    function cancel(uint256 receiverSeed) external {
        address receiver = _actor(receiverSeed);
        (uint256 pendingAssets, uint256 pendingShares) = VAULT.pendingRedeemRequest(receiver);
        vm.assume(pendingShares != 0);
        uint256 ledgerBefore = VAULT.totalPendingAssets();

        vm.prank(OWNER);
        VAULT.cancelRedeem(receiver);

        uint256 ledgerDelta = ledgerBefore - VAULT.totalPendingAssets();
        if (ledgerDelta != pendingAssets) revert ReleaseMismatch(ledgerDelta, pendingAssets);
        ghostReleased += pendingAssets;
    }

    function setPrice(uint256 price) external {
        price = bound(price, 5e5, 2e6);
        vm.mockCall(
            VAULT.ORACLE_ADDRESS(),
            abi.encodeWithSelector(IYoOracle.getLatestPrice.selector, address(VAULT)),
            abi.encode(price, uint64(block.timestamp))
        );
    }

    function setWithdrawFee(uint256 fee) external {
        fee = bound(fee, 0, 1e17 - 1);
        vm.prank(OWNER);
        VAULT.updateWithdrawFee(fee);
    }

    function _expectRefused(address receiver, uint256 shares, bool atCurrentPrice, bytes4 expected) internal {
        vm.prank(OWNER);
        try VAULT.fulfillRedeem(receiver, shares, atCurrentPrice) {
            revert GuardDidNotFire();
        } catch (bytes memory err) {
            if (bytes4(err) != expected) revert UnexpectedRevert(bytes4(err));
        }
    }
}
