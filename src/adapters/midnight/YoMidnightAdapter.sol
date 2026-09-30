// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBlueBuyCallback } from "../../interfaces/external/IBlueBuyCallback.sol";
import { Id, IMorpho, MarketParams } from "../../interfaces/IMorpho.sol";
import { IYoMidnightAdapter } from "../../interfaces/IYoMidnightAdapter.sol";
import { IYoMorphoMarketRegistry } from "../../interfaces/IYoMorphoMarketRegistry.sol";
import { IYoRegistry } from "../../interfaces/IYoRegistry.sol";
import { IMidnight, Market, Offer } from "../../vendor/morpho-midnight/interfaces/IMidnight.sol";
import {
    IBlueBuyCallbackFactory
} from "../../vendor/morpho-midnight/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import { ISetterRatifier } from "../../vendor/morpho-midnight/ratifiers/interfaces/ISetterRatifier.sol";
import { IdLib } from "../../vendor/morpho-midnight/libraries/IdLib.sol";
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
///             with `expiry <= maturity <= now + maxTimeToMaturity` and `continuousFeeCap <=
///             maxContinuousFeeCap`, funded by the vault's callback from an allowed Blue market with
///             the same loan token. Removing a market family or market from `registry` does not revoke
///             roots already ratified: also `unratify` them (see `MidnightRootSet`), raise the
///             group's `consumed` on Midnight, or defund the callback.
///         REGISTRY: `registry` is the shared `YoMorphoMarketRegistry`. It holds Blue market ids
///         (funding sources) and Morpho market family ids (`marketFamilyId`). A family is every
///         market that differs only by maturity, so one entry allows all maturities. The key
///         spaces do not collide: a family id is a CREATE2-style hash of a full `Market`, a Blue id
///         hashes a `MarketParams`.
///         VAULT SETUP (governance): `Midnight.setIsAuthorized(ratifier, true, vault)`,
///         `Midnight.setIsAuthorized(adapter, true, vault)`, and `callback.setAuthorization(adapter,
///         true)`. The operator must not get direct `manage` access to `ratifier.setIsRootRatified`,
///         `Midnight.setIsAuthorized`, `Midnight.take`, or `callback.setAuthorization`; that access
///         bypasses the offer checks in `ratify`.
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

    IMorpho public immutable morpho;
    IMidnight public immutable midnight;
    ISetterRatifier public immutable ratifier;
    IBlueBuyCallbackFactory public immutable callbackFactory;
    IYoMorphoMarketRegistry public immutable registry;
    /// @notice Upper bound on `maturity - block.timestamp` for ratified offers.
    uint256 public immutable maxTimeToMaturity;
    /// @notice Upper bound on `continuousFeeCap` for ratified offers, in Midnight's continuous-fee units.
    uint256 public immutable maxContinuousFeeCap;

    constructor(
        IMorpho _morpho,
        IMidnight _midnight,
        ISetterRatifier _ratifier,
        IBlueBuyCallbackFactory _callbackFactory,
        IYoMorphoMarketRegistry _registry,
        uint256 _maxTimeToMaturity,
        uint256 _maxContinuousFeeCap,
        IYoRegistry _yoRegistry
    )
        YoAdapterBase(_yoRegistry)
    {
        if (
            address(_registry) == address(0) || _maxTimeToMaturity == 0 || _ratifier.MIDNIGHT() != address(_midnight)
                || _callbackFactory.MIDNIGHT() != address(_midnight) || _callbackFactory.BLUE() != address(_morpho)
        ) {
            revert InvalidConfig();
        }
        morpho = _morpho;
        midnight = _midnight;
        ratifier = _ratifier;
        callbackFactory = _callbackFactory;
        registry = _registry;
        maxTimeToMaturity = _maxTimeToMaturity;
        maxContinuousFeeCap = _maxContinuousFeeCap;
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
}
