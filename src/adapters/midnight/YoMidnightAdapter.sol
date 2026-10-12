// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBlueBuyCallback } from "../../interfaces/external/IBlueBuyCallback.sol";
import { Id, IMorpho, MarketParams } from "../../interfaces/IMorpho.sol";
import { IYoMidnightAdapter } from "../../interfaces/IYoMidnightAdapter.sol";
import { IYoMidnightRegistry } from "../../interfaces/IYoMidnightRegistry.sol";
import { IYoMorphoMarketRegistry } from "../../interfaces/IYoMorphoMarketRegistry.sol";
import { IYoRegistry } from "../../interfaces/IYoRegistry.sol";
import { IMidnight, Market, Offer } from "../../vendor/morpho-midnight/interfaces/IMidnight.sol";
import {
    IBlueBuyCallbackFactory
} from "../../vendor/morpho-midnight/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import { ISetterRatifier } from "../../vendor/morpho-midnight/ratifiers/interfaces/ISetterRatifier.sol";
import { IdLib } from "../../vendor/morpho-midnight/libraries/IdLib.sol";
import { TickLib } from "../../vendor/morpho-midnight/libraries/TickLib.sol";
import { HashLib } from "../../vendor/morpho-midnight/ratifiers/libraries/HashLib.sol";
import { YoAdapterBase } from "../base/YoAdapterBase.sol";

/// @title  YoMidnightAdapter
/// @notice Immutable Morpho Midnight adapter. A vault quotes fixed-rate lend bids that are funded at
///         fill time by its Morpho `BlueBuyCallback`, which withdraws from a Blue variable-rate
///         position. The adapter funds and defunds that callback, ratifies offer trees after it
///         validates every offer, and redeems the vault's credit.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`.
///           - A callback is used only if `callbackFactory` created it and its `OWNER` is the vault.
///           - Funds that leave a callback or Midnight go only to the vault.
///           - At ratify time, every leaf is a vault buy offer via `ratifier`, in an allowed market family,
///             with `expiry <= maturity <= now + maxTimeToMaturity`, at least `minTerm` from the
///             earliest take to maturity, `continuousFeeCap <= maxContinuousFeeCap`, and a price
///             that earns at least `minRate` net of `continuousFeeCap`. The vault's callback funds it from an allowed
/// Blue market with the same loan token.
///           - `fundCallback` keeps `deployedAssets[vault] <= midnightRegistry.cap(vault)`, and
///             funds only in the vault's asset.
///         EXPOSURE: `deployedAssets` is the net principal that the vault sent through the adapter.
///         It adds each funding and subtracts each defund and redemption in the vault's asset,
///         floored at 0. A fill moves assets from the callback's Blue position to Midnight credit
///         and does not change it. The cap is a fixed amount per vault in `midnightRegistry`, not
///         a share of `totalAssets()`: that counts only the shares on this chain, and a deposit
///         can raise it. Limits:
///           - The cap applies only to new funding. It does not cap offer sizes.
///           - Assets that reach a callback without the adapter (anyone can supply to Blue on
///             behalf of a callback) are not counted. Fills can use them, and a later defund or
///             redeem of them lowers `deployedAssets`.
///           - Accrued Blue interest and the fill discount are not counted. A defund or redeem of
///             them also lowers `deployedAssets`, and this adds up across rolling positions.
///           - Realized losses, and assets that leave a callback without the adapter, are not
///             subtracted. Governance can change the cap to correct for this drift.
///         A vault without a cap cannot fund.
///         REVOCATION: the ratifier checks only the Merkle proof and the root, so removing a market
///         family or market from `registry` does not revoke roots already ratified. To revoke a
///         root, `unratify` it (see `MidnightRootSet`), raise the group's `consumed` on Midnight, or
///         remove its funding market from `registry` and defund the callback. Defunding alone is
///         not enough: the next `fundCallback` on the same callback and market makes the root
///         fillable again. Roots stay live until `expiry`, also after the operator loses its role.
///         `Midnight.setIsAuthorized(ratifier, false, vault)` stops every bid of the vault at once.
///         TAKER RISK: the taker of a vault bid is the seller, and Midnight books the units against
///         the seller's credit first. So a lender in the market can sell its credit to the vault,
///         also credit with bad debt that is not yet realized. The ratifier does not check the
///         taker, so the adapter cannot block this. Quote with a short `expiry`, and `unratify`
///         the bids of a market whose collateral price falls.
///         REGISTRY: `registry` is the shared `YoMorphoMarketRegistry`. It holds Blue market ids
///         (funding sources) and Morpho market family ids (`marketFamilyId`). A family is every
///         market that differs only by maturity, so one entry allows all maturities. The key
///         spaces do not collide: a family id is a CREATE2-style hash of a full `Market`, a Blue id
///         hashes a `MarketParams`.
///         VAULT SETUP (governance): `Midnight.setIsAuthorized(ratifier, true, vault)`,
///         `Midnight.setIsAuthorized(adapter, true, vault)`, `callback.setAuthorization(adapter,
///         true)`, and `midnightRegistry.setCap(vault, assets)`. Grant the operator only the
///         adapter selectors. Other `manage` access to Midnight, the ratifier, a callback, or Blue
///         on behalf of a callback (for example `Midnight.take`, `ratifier.setIsRootRatified`,
///         `callback.setAuthorization`, or `Blue.supply`) bypasses the checks in `ratify` or the
///         cap.
contract YoMidnightAdapter is YoAdapterBase, IYoMidnightAdapter {
    using SafeERC20 for IERC20;

    /// @notice Callback funding audit log.
    /// @param  vault        The calling YO vault (always `msg.sender`).
    /// @param  callback     The vault's `BlueBuyCallback`.
    /// @param  blueMarketId Morpho Blue market of the callback position.
    /// @param  direction    `Deposit` for fund, `Withdraw` for defund.
    /// @param  amount       Assets supplied or withdrawn.
    event MidnightCallbackAction(
        address indexed vault,
        address indexed callback,
        Id indexed blueMarketId,
        AdapterDirection direction,
        uint256 amount
    );

    /// @notice Emitted when the vault ratifies (`offerCount > 0`) or revokes (`offerCount == 0`) a root.
    event MidnightRootSet(address indexed vault, bytes32 indexed root, bool ratified, uint256 offerCount);

    uint256 internal constant WAD = 1e18;

    IMorpho public immutable morpho;
    IMidnight public immutable midnight;
    ISetterRatifier public immutable ratifier;
    IBlueBuyCallbackFactory public immutable callbackFactory;
    IYoMorphoMarketRegistry public immutable registry;
    /// @notice Per-vault cap on `deployedAssets`.
    IYoMidnightRegistry public immutable midnightRegistry;
    /// @notice Upper bound on `maturity - block.timestamp` for ratified offers.
    uint256 public immutable maxTimeToMaturity;
    /// @notice Lower bound on `maturity - max(block.timestamp, start)` for ratified offers. With
    ///         `minRate`, it sets the smallest discount to par: about `minRate * minTerm`.
    uint256 public immutable minTerm;
    /// @notice Upper bound on `continuousFeeCap` for ratified offers, in Midnight's continuous-fee units.
    uint256 public immutable maxContinuousFeeCap;
    /// @notice Lower bound on the rate of ratified offers: simple interest, WAD per second, as
    ///         Midnight's `continuousFee`. The rate is net of the offer's `continuousFeeCap` and
    ///         counts from the earliest take time to maturity.
    uint256 public immutable minRate;

    /// @inheritdoc IYoMidnightAdapter
    mapping(address vault => uint256 assets) public deployedAssets;

    constructor(
        IMorpho _morpho,
        IMidnight _midnight,
        ISetterRatifier _ratifier,
        IBlueBuyCallbackFactory _callbackFactory,
        IYoMorphoMarketRegistry _registry,
        IYoMidnightRegistry _midnightRegistry,
        uint256 _maxTimeToMaturity,
        uint256 _minTerm,
        uint256 _maxContinuousFeeCap,
        uint256 _minRate,
        IYoRegistry _yoRegistry
    )
        YoAdapterBase(_yoRegistry)
    {
        if (
            address(_registry) == address(0) || address(_midnightRegistry) == address(0) || _minTerm == 0
                || _minTerm > _maxTimeToMaturity || _minRate == 0 || _ratifier.MIDNIGHT() != address(_midnight)
                || _callbackFactory.MIDNIGHT() != address(_midnight) || _callbackFactory.BLUE() != address(_morpho)
        ) {
            revert InvalidConfig();
        }
        morpho = _morpho;
        midnight = _midnight;
        ratifier = _ratifier;
        callbackFactory = _callbackFactory;
        registry = _registry;
        midnightRegistry = _midnightRegistry;
        maxTimeToMaturity = _maxTimeToMaturity;
        minTerm = _minTerm;
        maxContinuousFeeCap = _maxContinuousFeeCap;
        minRate = _minRate;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  CALLBACK FUNDING
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoMidnightAdapter
    function fundCallback(
        address callback,
        Id blueMarketId,
        uint256 assets
    )
        external
        nonReentrant
        returns (uint256 assetsSupplied, uint256 sharesSupplied)
    {
        if (assets == 0) {
            revert InvalidAmount();
        }
        address vault = msg.sender;
        if (!registry.isAllowed(vault, blueMarketId)) {
            revert MarketNotAllowed(blueMarketId);
        }
        if (!_isVaultCallback(vault, callback)) {
            revert InvalidCallback(callback);
        }
        // Without this authorization `defundCallback` cannot return the funds to the vault.
        if (!morpho.isAuthorized(callback, address(this))) {
            revert CallbackNotAuthorized(callback);
        }
        MarketParams memory p = _marketParams(blueMarketId);
        _reserveExposure(vault, p.loanToken, assets);

        IERC20 token = IERC20(p.loanToken);
        uint256 sharesBefore = morpho.position(blueMarketId, callback).supplyShares;

        token.safeTransferFrom(vault, address(this), assets);
        token.forceApprove(address(morpho), assets);

        (assetsSupplied, sharesSupplied) = morpho.supply(p, assets, 0, callback, "");

        token.forceApprove(address(morpho), 0);

        if (morpho.position(blueMarketId, callback).supplyShares <= sharesBefore) {
            revert NoShareDelta();
        }

        emit MidnightCallbackAction(vault, callback, blueMarketId, AdapterDirection.Deposit, assetsSupplied);
    }

    /// @inheritdoc IYoMidnightAdapter
    /// @dev Not gated by `registry`: funds only return to the vault, so exits stay open after a
    ///      market is removed.
    function defundCallback(
        address callback,
        Id blueMarketId,
        uint256 assets
    )
        external
        nonReentrant
        returns (uint256 assetsWithdrawn, uint256 sharesBurned)
    {
        if (assets == 0) {
            revert InvalidAmount();
        }
        address vault = msg.sender;
        if (!_isVaultCallback(vault, callback)) {
            revert InvalidCallback(callback);
        }
        MarketParams memory p = _marketParams(blueMarketId);

        (assetsWithdrawn, sharesBurned) = morpho.withdraw(p, assets, 0, callback, vault);
        _releaseExposure(vault, p.loanToken, assetsWithdrawn);

        emit MidnightCallbackAction(vault, callback, blueMarketId, AdapterDirection.Withdraw, assetsWithdrawn);
    }

    /// @inheritdoc IYoMidnightAdapter
    /// @dev Not gated by `registry`, as for `defundCallback`.
    function defundCallbackAll(
        address callback,
        Id blueMarketId
    )
        external
        nonReentrant
        returns (uint256 assetsWithdrawn, uint256 sharesBurned)
    {
        address vault = msg.sender;
        if (!_isVaultCallback(vault, callback)) {
            revert InvalidCallback(callback);
        }
        MarketParams memory p = _marketParams(blueMarketId);

        uint256 shares = morpho.position(blueMarketId, callback).supplyShares;
        if (shares == 0) {
            revert NoPosition(blueMarketId);
        }

        (assetsWithdrawn, sharesBurned) = morpho.withdraw(p, 0, shares, callback, vault);
        _releaseExposure(vault, p.loanToken, assetsWithdrawn);

        emit MidnightCallbackAction(vault, callback, blueMarketId, AdapterDirection.Withdraw, assetsWithdrawn);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      QUOTES
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoMidnightAdapter
    /// @dev The offers are the tree leaves in order. Pad to a power of two by repeating a real offer.
    ///      A leaf equal to the previous leaf is the same offer, so its checks are skipped.
    function ratify(Offer[] calldata offers) external nonReentrant returns (bytes32 root) {
        address vault = msg.sender;
        uint256 count = offers.length;
        bytes32[] memory leaves = new bytes32[](count);
        for (uint256 i = 0; i < count; ++i) {
            leaves[i] = HashLib.hashOffer(offers[i]);
            if (i > 0 && leaves[i] == leaves[i - 1]) {
                continue;
            }
            _validateOffer(vault, offers[i], i);
            _validateFunding(vault, offers[i], i);
        }
        root = _root(leaves);

        ratifier.setIsRootRatified(vault, root, true);

        emit MidnightRootSet(vault, root, true, count);
    }

    /// @inheritdoc IYoMidnightAdapter
    function unratify(bytes32 root) external nonReentrant {
        ratifier.setIsRootRatified(msg.sender, root, false);

        emit MidnightRootSet(msg.sender, root, false, 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     REDEMPTION
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoMidnightAdapter
    /// @dev Not gated by `registry`: funds only return to the vault. Midnight sends exactly `units`
    ///      of loan token.
    function redeem(Market calldata market, uint256 units) external nonReentrant {
        if (units == 0) {
            revert InvalidAmount();
        }
        midnight.withdraw(market, units, msg.sender, msg.sender);
        _releaseExposure(msg.sender, market.loanToken, units);

        _emitAction(address(midnight), market.loanToken, AdapterDirection.Withdraw, units);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                       VIEWS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoMidnightAdapter
    /// @dev Matches Morpho's `market_family_id` (Morpho API and app): the Midnight id of the same
    ///      market with `maturity = 0`.
    function marketFamilyId(Market calldata market) public pure returns (Id) {
        Market memory family = market;
        family.maturity = 0;
        return Id.wrap(IdLib.toId(family));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     INTERNALS
    //////////////////////////////////////////////////////////////////////////*/

    function _validateOffer(address vault, Offer calldata offer, uint256 index) internal view {
        if (offer.maker != vault) {
            revert InvalidMaker(index);
        }
        if (!offer.buy) {
            revert NotBuyOffer(index);
        }
        if (offer.ratifier != address(ratifier)) {
            revert InvalidRatifier(index);
        }

        Id family = marketFamilyId(offer.market);
        if (!registry.isAllowed(vault, family)) {
            revert FamilyNotAllowed(index, family);
        }
        uint256 maturity = offer.market.maturity;
        if (maturity <= block.timestamp || maturity - block.timestamp > maxTimeToMaturity) {
            revert MaturityOutOfRange(index);
        }
        if (offer.expiry > maturity) {
            revert ExpiryAfterMaturity(index);
        }
        if (offer.continuousFeeCap > maxContinuousFeeCap) {
            revert ContinuousFeeCapTooHigh(index);
        }
        _validateRate(offer, index);
    }

    /// @dev The vault pays `price` per unit at the take and gets 1 per unit at maturity, less the
    ///      continuous fee (at most `continuousFeeCap * timeToMaturity` per unit). The price does
    ///      not change with time, so the rate is lowest at the earliest take: `max(now, start)`.
    ///      Requires `(1 - fee) >= price * (1 + minRate * timeToMaturity)`, in WAD, and
    ///      `timeToMaturity >= minTerm`: near 0, the check passes a price at par.
    function _validateRate(Offer calldata offer, uint256 index) internal view {
        uint256 earliestTake = offer.start > block.timestamp ? offer.start : block.timestamp;
        uint256 maturity = offer.market.maturity;
        if (maturity <= earliestTake || maturity - earliestTake < minTerm) {
            revert TermTooShort(index);
        }
        uint256 timeToMaturity = maturity - earliestTake;
        uint256 fee = offer.continuousFeeCap * timeToMaturity;
        if (fee >= WAD || TickLib.tickToPrice(offer.tick) * (WAD + minRate * timeToMaturity) > (WAD - fee) * WAD) {
            revert RateBelowMin(index);
        }
    }

    function _validateFunding(address vault, Offer calldata offer, uint256 index) internal view {
        if (!_isVaultCallback(vault, offer.callback)) {
            revert OfferCallbackNotAllowed(index, offer.callback);
        }
        // Decoded exactly as `BlueBuyCallback.onBuy` decodes it.
        MarketParams memory p = abi.decode(offer.callbackData, (MarketParams));
        Id blueMarketId = Id.wrap(keccak256(abi.encode(p)));
        if (!registry.isAllowed(vault, blueMarketId)) {
            revert FundingMarketNotAllowed(index, blueMarketId);
        }
        if (p.loanToken != offer.market.loanToken) {
            revert LoanTokenMismatch(index);
        }
    }

    /// @dev Merkle root of `leaves`, built the way Midnight's `HashLib.isLeaf` verifies it: the leaf
    ///      count is a power of two and leaf `i` sits at index `i`. Overwrites `leaves` in place.
    function _root(bytes32[] memory leaves) internal pure returns (bytes32) {
        uint256 n = leaves.length;
        if (n == 0 || n & (n - 1) != 0) {
            revert LeafCountNotPowerOfTwo(n);
        }
        while (n > 1) {
            n /= 2;
            for (uint256 i = 0; i < n; ++i) {
                leaves[i] = HashLib.hashNode(leaves[2 * i], leaves[2 * i + 1]);
            }
        }
        return leaves[0];
    }

    function _isVaultCallback(address vault, address callback) internal view returns (bool) {
        return callbackFactory.isBlueBuyCallback(callback) && IBlueBuyCallback(callback).OWNER() == vault;
    }

    function _marketParams(Id blueMarketId) internal view returns (MarketParams memory p) {
        p = morpho.idToMarketParams(blueMarketId);
        if (p.loanToken == address(0)) {
            revert UnknownMarket(blueMarketId);
        }
    }

    /// @dev Checks the cap and adds `assets` to `deployedAssets`. Funding must be in the vault's
    ///      asset, the unit of the cap.
    function _reserveExposure(address vault, address loanToken, uint256 assets) internal {
        if (!_isVaultAsset(vault, loanToken)) {
            revert LoanTokenNotVaultAsset(loanToken);
        }
        uint256 deployed = deployedAssets[vault] + assets;
        uint256 cap = midnightRegistry.cap(vault);
        if (deployed > cap) {
            revert ExposureCapExceeded(deployed, cap);
        }
        deployedAssets[vault] = deployed;
    }

    /// @dev Subtracts `assets` from `deployedAssets`, floored at 0. Counts only the vault's asset:
    ///      anyone can supply any token to a callback's Blue position, so other tokens must not
    ///      lower `deployedAssets`.
    function _releaseExposure(address vault, address loanToken, uint256 assets) internal {
        if (!_isVaultAsset(vault, loanToken)) {
            return;
        }
        uint256 deployed = deployedAssets[vault];
        deployedAssets[vault] = assets < deployed ? deployed - assets : 0;
    }

    function _isVaultAsset(address vault, address token) internal view returns (bool) {
        return token == IERC4626(vault).asset();
    }
}
