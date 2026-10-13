// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IBlueBuyCallback } from "./../../interfaces/external/IBlueBuyCallback.sol";
import { Id, IMorpho, MarketParams } from "./../../interfaces/IMorpho.sol";
import { IYoMidnightAdapter } from "./../../interfaces/IYoMidnightAdapter.sol";
import { IYoMidnightRegistry } from "./../../interfaces/IYoMidnightRegistry.sol";
import { IYoMorphoMarketRegistry } from "./../../interfaces/IYoMorphoMarketRegistry.sol";
import { IYoRegistry } from "./../../interfaces/IYoRegistry.sol";
import { IMidnight, Market, Offer } from "./../../vendor/morpho-midnight/interfaces/IMidnight.sol";
import { IdLib } from "./../../vendor/morpho-midnight/libraries/IdLib.sol";
import { TickLib } from "./../../vendor/morpho-midnight/libraries/TickLib.sol";
import {
    IBlueBuyCallbackFactory
} from "./../../vendor/morpho-midnight/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import { ISetterRatifier } from "./../../vendor/morpho-midnight/ratifiers/interfaces/ISetterRatifier.sol";
import { HashLib } from "./../../vendor/morpho-midnight/ratifiers/libraries/HashLib.sol";
import { YoAdapterBase } from "./../base/YoAdapterBase.sol";

/// @title  YoMidnightAdapter
/// @notice Immutable Morpho Midnight adapter. A vault quotes fixed-rate lend bids that its `BlueBuyCallback`
///         funds at fill time from a Blue position. The adapter funds and defunds the callback, validates and
///         ratifies offer trees, and redeems credit. Funds leave a callback or Midnight only to the vault.
/// @dev    `msg.sender` is the vault (`YoVault.manage`).
///         EXPOSURE: `deployedAssets` is the net principal sent through the adapter, floored at 0. It does not
///         count Blue supplies outside the adapter, interest, or losses. Governance corrects this drift with the
///         cap in `midnightRegistry`. A vault without a cap cannot fund.
///         REVOCATION: removing a market from `registry` does not revoke ratified roots. Use `unratify`, raise
///         `consumed` on Midnight, or deauthorize `ratifier`. A defund alone is not enough: the next
///         `fundCallback` makes the root fillable again.
///         TAKER RISK: a lender can sell its credit, also bad debt, to a vault bid. Quote with a short `expiry`.
///         VAULT SETUP: authorize `ratifier` and the adapter on Midnight, the adapter on the callback, and set the
///         cap. Grant the operator only the adapter selectors: other `manage` access to Midnight, `ratifier`, a
///         callback, or Blue bypasses the `ratify` checks or the cap.
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
    IYoMidnightRegistry public immutable midnightRegistry;
    /// @notice Maximum `maturity - now` of a ratified offer.
    uint256 public immutable maxTimeToMaturity;
    /// @notice Minimum `maturity - max(now, start)` of a ratified offer.
    uint256 public immutable minTerm;
    /// @notice Maximum `continuousFeeCap` of a ratified offer.
    uint256 public immutable maxContinuousFeeCap;
    /// @notice Minimum rate of a ratified offer, net of `continuousFeeCap`: simple interest, WAD per second.
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
        // `defundCallback` needs it.
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
    /// @dev Not gated by `registry`, so exits stay open.
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
    /// @dev Not gated by `registry`.
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
    /// @dev Offers are the leaves in order. Pad to a power of two by repeating the previous offer, which is not
    ///      checked again.
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
    /// @dev Not gated by `registry`. Midnight sends exactly `units` of loan token.
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
    /// @dev Morpho's `market_family_id`: the Midnight id of `market` with `maturity = 0`.
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

    /// @dev With `t = maturity - max(now, start)`, requires `t >= minTerm` and
    ///      `price * (1 + minRate * t) <= 1 - continuousFeeCap * t`, in WAD.
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
        // As `BlueBuyCallback.onBuy` decodes it.
        MarketParams memory p = abi.decode(offer.callbackData, (MarketParams));
        Id blueMarketId = Id.wrap(keccak256(abi.encode(p)));
        if (!registry.isAllowed(vault, blueMarketId)) {
            revert FundingMarketNotAllowed(index, blueMarketId);
        }
        if (p.loanToken != offer.market.loanToken) {
            revert LoanTokenMismatch(index);
        }
    }

    /// @dev Merkle root in the layout of Midnight's `HashLib.isLeaf`. Overwrites `leaves`.
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

    /// @dev Funding must be in the vault's asset, the unit of the cap.
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

    /// @dev Ignores other tokens: anyone can supply them to a callback.
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
