// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Market, Offer } from "../vendor/morpho-midnight/interfaces/IMidnight.sol";
import { Id } from "./IMorpho.sol";

/// @notice Morpho Midnight fixed-rate lending adapter for YO vaults.
interface IYoMidnightAdapter {
    error InvalidAmount();
    error InvalidConfig();
    error MarketNotAllowed(Id id);
    error UnknownMarket(Id id);
    error NoPosition(Id id);
    error NoShareDelta();
    error InvalidCallback(address callback);
    error CallbackNotAuthorized(address callback);
    error InvalidMaker(uint256 index);
    error NotBuyOffer(uint256 index);
    error InvalidRatifier(uint256 index);
    error FamilyNotAllowed(uint256 index, Id familyId);
    error MaturityOutOfRange(uint256 index);
    error TermTooShort(uint256 index);
    error ExpiryAfterMaturity(uint256 index);
    error ContinuousFeeCapTooHigh(uint256 index);
    error RateBelowMin(uint256 index);
    error OfferCallbackNotAllowed(uint256 index, address callback);
    error FundingMarketNotAllowed(uint256 index, Id blueMarketId);
    error LoanTokenMismatch(uint256 index);
    error LeafCountNotPowerOfTwo(uint256 count);
    error LoanTokenNotVaultAsset(address loanToken);
    error ExposureCapExceeded(uint256 deployed, uint256 cap);

    /// @notice Supply `assets` of the vault's asset to `blueMarketId` on behalf of the vault's `callback`,
    ///         within the vault's cap.
    function fundCallback(
        address callback,
        Id blueMarketId,
        uint256 assets
    )
        external
        returns (uint256 assetsSupplied, uint256 sharesSupplied);

    /// @notice Withdraw `assets` from the `callback`'s position in `blueMarketId` to the vault.
    function defundCallback(
        address callback,
        Id blueMarketId,
        uint256 assets
    )
        external
        returns (uint256 assetsWithdrawn, uint256 sharesBurned);

    /// @notice Withdraw the `callback`'s full position in `blueMarketId` to the vault.
    function defundCallbackAll(
        address callback,
        Id blueMarketId
    )
        external
        returns (uint256 assetsWithdrawn, uint256 sharesBurned);

    /// @notice Validate every offer, build the Merkle root, and ratify it for the vault.
    function ratify(Offer[] calldata offers) external returns (bytes32 root);

    /// @notice Revoke the vault's ratification of `root`.
    function unratify(bytes32 root) external;

    /// @notice Burn `units` of the vault's credit in `market` and send the loan token to the vault.
    function redeem(Market calldata market, uint256 units) external;

    /// @notice Funded less defunded and redeemed, in the vault's asset, floored at 0.
    function deployedAssets(address vault) external view returns (uint256 assets);

    /// @notice Morpho market family id of `market`: the registry key that allows all its maturities.
    function marketFamilyId(Market calldata market) external pure returns (Id);
}
