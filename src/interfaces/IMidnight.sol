// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

/// @notice Static parameters defining a Morpho Midnight market. Vendored verbatim from
///         `morpho-org/midnight` `src/interfaces/IMidnight.sol` so offer hashing matches on-chain.
struct Market {
    uint256 chainId;
    address midnight;
    address loanToken;
    CollateralParams[] collateralParams;
    uint256 maturity;
    uint256 rcfThreshold;
    address enterGate;
    address liquidatorGate;
}

/// @notice Per-collateral risk parameters of a Midnight market.
struct CollateralParams {
    address token;
    uint256 lltv;
    uint256 liquidationCursor;
    address oracle;
}

/// @notice An off-chain lending/borrowing offer settled through `IMidnight.take`.
/// @dev `maxAssets` is `buyerAssets` if `buy` else `sellerAssets`.
struct Offer {
    Market market;
    bool buy;
    address maker;
    uint256 start;
    uint256 expiry;
    uint256 tick;
    bytes32 group;
    address callback;
    bytes callbackData;
    address receiverIfMakerIsSeller;
    address ratifier;
    bool reduceOnly;
    uint128 maxUnits;
    uint128 maxAssets;
    uint256 continuousFeeCap;
}

/// @notice Minimal Morpho Midnight interface.
/// @dev Subset of the official interface limited to the methods invoked by `YoMidnightAdapter`
///      and its fork tests. See `morpho-org/midnight` for the full contract.
interface IMidnight {
    /// @notice Settles an offer, transferring `units` of credit between maker and taker.
    /// @return buyerAssets Loan-token assets paid by the buyer (fee inclusive).
    /// @return sellerAssets Loan-token assets received by the seller.
    function take(
        Offer memory offer,
        bytes memory ratifierData,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes memory takerCallbackData
    )
        external
        returns (uint256 buyerAssets, uint256 sellerAssets);

    /// @notice Burns `units` of credit for `onBehalf` and sends `units` loan tokens to `receiver`.
    function withdraw(Market memory market, uint256 units, address onBehalf, address receiver) external;

    /// @notice Sets the consumed amount of a group's shared budget, hard-cancelling offers when raised.
    function setConsumed(bytes32 group, uint128 amount, address onBehalf) external;

    /// @notice Grants or revokes delegation of `onBehalf`'s Midnight actions to `authorized`.
    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external;

    /// @notice Validates `market` and returns its id, creating the market on first touch.
    function touchMarket(Market memory market) external returns (bytes32);

    /// @notice Read-only accrual: returns the position `user` would hold in market `id` after loss
    ///         factor and continuous fees are applied, without mutating state. The values match what
    ///         a subsequent `take` / `withdraw` accrues in the same block.
    function updatePositionView(
        Market memory market,
        bytes32 id,
        address user
    )
        external
        view
        returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee);

    /// @notice Whether `authorizer` has authorized `authorized` to act on its behalf.
    function isAuthorized(address authorizer, address authorized) external view returns (bool);

    /// @notice Current credit units held by `user` in market `id`.
    function credit(bytes32 id, address user) external view returns (uint128);

    /// @notice Loan-token units currently withdrawable from market `id` (grows as borrowers repay).
    function withdrawable(bytes32 id) external view returns (uint128);
}

/// @notice Minimal interface for Midnight's `SetterRatifier` — the on-chain root-ratification ratifier.
/// @dev A maker (or an account it authorized on Midnight) marks a Merkle root of offer hashes as
///      ratified; `take` then accepts any offer whose leaf proves into a ratified root.
interface ISetterRatifier {
    /// @notice Marks `root` as ratified (or not) for `maker`. Caller must be `maker` or authorized by
    ///         it on Midnight.
    function setIsRootRatified(address maker, bytes32 root, bool newIsRootRatified) external;

    /// @notice Whether `root` is currently ratified for `maker`.
    function isRootRatified(address maker, bytes32 root) external view returns (bool);
}
