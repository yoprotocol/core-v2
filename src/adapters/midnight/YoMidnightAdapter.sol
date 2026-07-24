// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMidnight, ISetterRatifier, Market, Offer } from "../../interfaces/IMidnight.sol";
import { IYoMidnightAdapter } from "../../interfaces/IYoMidnightAdapter.sol";
import { IYoMidnightMarketRegistry } from "../../interfaces/IYoMidnightMarketRegistry.sol";
import { IYoRegistry } from "../../interfaces/IYoRegistry.sol";
import { MidnightHashLib } from "../../libraries/MidnightHashLib.sol";
import { YoAdapterBase } from "../base/YoAdapterBase.sol";

/// @title  YoMidnightAdapter
/// @notice Immutable Morpho Midnight lending adapter: `makeOrder`/`makeOrders` (quote), `cancelOrder`/
///         `cancelGroup` (retract), `takeBuy`/`takeSell` (fill), and `withdraw`/`withdrawAll` (redeem).
///         Lender-only — the vault only ever buys credit or exits credit it already holds, never
///         incurs debt. Every maker offer is validated field-by-field on-chain and ratified as a
///         single-leaf root, so a compromised keeper cannot commit the vault to unlisted markets or
///         redirected recipients.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`; it is always the
///             offer `maker` (make/cancel), the `taker` (take), and Midnight `onBehalf`/`receiver`.
///           - Maker offers carry an empty callback and (when the vault sells) `reduceOnly == true`
///             with `receiverIfMakerIsSeller == vault`, so proceeds cannot be redirected and debt
///             cannot be created.
///           - `takeBuy` bounds the vault→Midnight pull to `maxAssets` and sweeps the full remaining
///             loan-token balance back to the vault (covering rounding slack + pre-existing dust).
///           - Midnight callbacks are never used (`takerCallback == 0`, empty data).
contract YoMidnightAdapter is YoAdapterBase, IYoMidnightAdapter {
    using SafeERC20 for IERC20;

    /// @notice Vault-level Midnight audit log. Replaces the generic `AdapterAction` because the
    ///         Midnight singleton spans all markets — `marketId` is the discriminator, not the target.
    /// @param  vault     The calling YO vault (always `msg.sender`).
    /// @param  marketId  Midnight market identifier.
    /// @param  direction `Deposit` when the vault buys credit (`takeBuy`); `Withdraw` when it exits
    ///                   credit (`takeSell`) or redeems (`withdraw` / `withdrawAll`).
    /// @param  units     Credit units bought, sold, or redeemed.
    /// @param  assets    Loan-token assets paid (buy) or received (sell / redeem).
    event MidnightMarketAction(
        address indexed vault,
        bytes32 indexed marketId,
        AdapterDirection direction,
        uint256 units,
        uint256 assets
    );

    IMidnight public immutable midnight;
    ISetterRatifier public immutable setterRatifier;
    IYoMidnightMarketRegistry public immutable registry;

    constructor(
        IMidnight _midnight,
        ISetterRatifier _setterRatifier,
        IYoMidnightMarketRegistry _registry,
        IYoRegistry _yoRegistry
    )
        YoAdapterBase(_yoRegistry)
    {
        midnight = _midnight;
        setterRatifier = _setterRatifier;
        registry = _registry;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   MAKE / CANCEL
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoMidnightAdapter
    function makeOrder(Offer calldata offer) external nonReentrant returns (bytes32 root) {
        root = _makeOrder(offer);
    }

    /// @inheritdoc IYoMidnightAdapter
    function makeOrders(Offer[] calldata offers) external nonReentrant returns (bytes32[] memory roots) {
        roots = new bytes32[](offers.length);
        for (uint256 i = 0; i < offers.length; i++) {
            roots[i] = _makeOrder(offers[i]);
        }
    }

    /// @inheritdoc IYoMidnightAdapter
    /// @dev No market-allowlist check: cancellation must succeed even after a market is de-listed.
    function cancelOrder(Offer calldata offer) external nonReentrant returns (bytes32 root) {
        address vault = msg.sender;
        if (offer.maker != vault) {
            revert NotOfferMaker();
        }
        root = MidnightHashLib.hashOffer(offer);
        // Confirm the exact offer is actually ratified before unratifying: a mutated offer hashes to a
        // different root, so a naive unratify would be a silent no-op while emitting OrderCancelled —
        // leaving the real offer live and takeable but marked cancelled to off-chain indexers.
        if (!setterRatifier.isRootRatified(vault, root)) {
            revert RootNotRatified();
        }
        setterRatifier.setIsRootRatified(vault, root, false);
        emit OrderCancelled(vault, root);
    }

    /// @inheritdoc IYoMidnightAdapter
    /// @dev Hard-cancels every offer sharing `group` by maxing out the group's consumed budget.
    function cancelGroup(bytes32 group) external nonReentrant {
        address vault = msg.sender;
        midnight.setConsumed(group, type(uint128).max, vault);
        emit GroupCancelled(vault, group);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                       TAKE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoMidnightAdapter
    /// @dev Vault buys credit from a maker sell offer (`offer.buy == false`). Pulls `maxAssets` loan
    ///      tokens from the vault to fund Midnight's direct debit, then sweeps the remainder back.
    function takeBuy(
        Offer calldata offer,
        bytes calldata ratifierData,
        uint256 units,
        uint256 maxAssets
    )
        external
        nonReentrant
        returns (uint256 buyerAssets, uint256 creditReceived)
    {
        if (units == 0 || maxAssets == 0) {
            revert InvalidAmount();
        }
        if (offer.buy) {
            revert WrongOfferSide();
        }
        address vault = msg.sender;
        bytes32 id = midnight.touchMarket(offer.market);
        if (!registry.isAllowed(vault, id)) {
            revert MarketNotAllowed(id);
        }

        IERC20 token = IERC20(offer.market.loanToken);
        // Baseline the credit AFTER accrual: `take` internally accrues the buyer's position (loss
        // factor + continuous fee), which can shrink a pre-existing credit balance. Reading the raw
        // pre-accrual balance here would fold that shrink into the delta below — understating the
        // units bought, or underflowing to a spurious revert when the accrued loss exceeds them. The
        // view yields the same accrued figure `take` will settle to, without an extra state write.
        (uint256 creditBefore,,) = midnight.updatePositionView(offer.market, id, vault);

        token.safeTransferFrom(vault, address(this), maxAssets);
        token.forceApprove(address(midnight), maxAssets);

        (buyerAssets,) = midnight.take(offer, ratifierData, units, vault, address(0), address(0), "");

        token.forceApprove(address(midnight), 0);

        creditReceived = midnight.credit(id, vault) - creditBefore;
        if (creditReceived == 0) {
            revert NoCreditDelta();
        }

        // Sweep rounding slack (maxAssets − buyerAssets) plus any pre-existing dust back to the vault.
        uint256 remaining = token.balanceOf(address(this));
        if (remaining != 0) {
            token.safeTransfer(vault, remaining);
        }

        emit MidnightMarketAction(vault, id, AdapterDirection.Deposit, creditReceived, buyerAssets);
    }

    /// @inheritdoc IYoMidnightAdapter
    /// @dev Vault sells credit it already holds into a maker buy offer (`offer.buy == true`). The
    ///      `credit >= units` guard is the lender-only invariant: it forbids the seller shortfall
    ///      that would otherwise open a debt position. Proceeds settle straight to the vault.
    function takeSell(
        Offer calldata offer,
        bytes calldata ratifierData,
        uint256 units,
        uint256 minAssets
    )
        external
        nonReentrant
        returns (uint256 sellerAssets)
    {
        if (units == 0) {
            revert InvalidAmount();
        }
        if (!offer.buy) {
            revert WrongOfferSide();
        }
        address vault = msg.sender;
        bytes32 id = midnight.touchMarket(offer.market);
        if (!registry.isAllowed(vault, id)) {
            revert MarketNotAllowed(id);
        }
        // The vault sells at the counterparty offer's tick; enforce the same registry price floor as
        // maker sells so a compromised operator cannot fill against a zero/low-priced buy offer.
        if (offer.tick < registry.minTickOf(vault, id)) {
            revert TickBelowFloor();
        }

        (uint128 credit,,) = midnight.updatePositionView(offer.market, id, vault);
        if (credit < units) {
            revert InsufficientCredit();
        }

        (, sellerAssets) = midnight.take(offer, ratifierData, units, vault, vault, address(0), "");
        if (sellerAssets < minAssets) {
            revert SlippageExceeded();
        }

        emit MidnightMarketAction(vault, id, AdapterDirection.Withdraw, units, sellerAssets);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     WITHDRAW
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoMidnightAdapter
    function withdraw(Market calldata market, uint256 units) external nonReentrant {
        if (units == 0) {
            revert InvalidAmount();
        }
        address vault = msg.sender;
        bytes32 id = midnight.touchMarket(market);
        if (!registry.isAllowed(vault, id)) {
            revert MarketNotAllowed(id);
        }

        midnight.withdraw(market, units, vault, vault);

        emit MidnightMarketAction(vault, id, AdapterDirection.Withdraw, units, units);
    }

    /// @inheritdoc IYoMidnightAdapter
    /// @dev Redeems `min(credit, withdrawable)`: post-maturity credit only becomes withdrawable as
    ///      borrowers repay, so a full-credit `withdraw` would underflow inside Midnight.
    function withdrawAll(Market calldata market) external nonReentrant returns (uint256 units) {
        address vault = msg.sender;
        bytes32 id = midnight.touchMarket(market);
        if (!registry.isAllowed(vault, id)) {
            revert MarketNotAllowed(id);
        }

        (uint128 credit,,) = midnight.updatePositionView(market, id, vault);
        uint256 available = midnight.withdrawable(id);
        units = credit < available ? credit : available;
        if (units == 0) {
            revert NoPosition();
        }

        midnight.withdraw(market, units, vault, vault);

        emit MidnightMarketAction(vault, id, AdapterDirection.Withdraw, units, units);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     INTERNAL
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Validates every offer field, then ratifies the single-leaf root `hashOffer(offer)`.
    ///      `SetterRatifier` re-checks that the adapter is authorized by the vault on Midnight.
    function _makeOrder(Offer calldata offer) internal returns (bytes32 root) {
        address vault = msg.sender;
        bytes32 id = midnight.touchMarket(offer.market);
        if (!registry.isAllowed(vault, id)) {
            revert MarketNotAllowed(id);
        }
        _validateMakerOffer(offer, vault);
        // Sell offers give up the vault's credit, so enforce the registry price floor (tick is a
        // monotonic proxy for price). Buy offers only spend `maxAssets`, which is bounded on its own.
        if (!offer.buy && offer.tick < registry.minTickOf(vault, id)) {
            revert TickBelowFloor();
        }

        root = MidnightHashLib.hashOffer(offer);
        setterRatifier.setIsRootRatified(vault, root, true);
        emit OrderMade(vault, id, root);
    }

    /// @dev Enforces the field constraints that make a vault offer safe and takeable: the vault is
    ///      the maker, the ratifier is our SetterRatifier, the callback is empty, exactly one size
    ///      cap is set (Midnight's rule), and the side-specific receiver / reduce-only invariants
    ///      hold. Reverts with a per-field error; performs no state changes.
    function _validateMakerOffer(Offer calldata offer, address vault) internal view {
        if (offer.maker != vault) {
            revert NotOfferMaker();
        }
        if (offer.ratifier != address(setterRatifier)) {
            revert InvalidRatifier();
        }
        if (offer.callback != address(0)) {
            revert CallbackNotEmpty();
        }
        // Midnight's own take-side rule: exactly one of maxAssets / maxUnits must be non-zero.
        if ((offer.maxAssets == 0) == (offer.maxUnits == 0)) {
            revert InvalidOfferCaps();
        }
        _validateOfferSide(offer, vault);
    }

    /// @dev Side-specific receiver / reduce-only / cap rules. Split out of `_validateMakerOffer` to
    ///      keep each function's branch count within the linter's cyclomatic-complexity bound.
    function _validateOfferSide(Offer calldata offer, address vault) internal pure {
        if (offer.buy) {
            // Vault lends (maker is buyer): Midnight requires the unused seller receiver to be zero.
            if (offer.receiverIfMakerIsSeller != address(0)) {
                revert InvalidReceiver();
            }
        } else {
            // Vault exits credit (maker is seller): proceeds must return to the vault and the offer
            // must be reduce-only so filling it can never open a debt position.
            if (offer.receiverIfMakerIsSeller != vault) {
                revert InvalidReceiver();
            }
            if (!offer.reduceOnly) {
                revert NotReduceOnly();
            }
            // Sell offers must cap by units, not assets. When a fill rounds `sellerAssets` toward zero
            // (e.g. a low tick), an asset cap's `consumed` never advances and the offer stays
            // refillable until expiry; a unit cap bounds the total credit that can ever leave the vault.
            if (offer.maxUnits == 0) {
                revert SellCapMustBeUnits();
            }
        }
    }
}
