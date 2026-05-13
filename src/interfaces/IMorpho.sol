// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Morpho Blue market identifier.
type Id is bytes32;

/// @notice Static parameters defining a Morpho Blue market.
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice On-chain position state for a user in a market.
struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

/// @notice Minimal Morpho Blue interface.
/// @dev Subset of the official interface limited to the methods invoked by adapters in this codebase.
interface IMorpho {
    function idToMarketParams(Id id) external view returns (MarketParams memory);

    function position(Id id, address user) external view returns (Position memory);

    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    )
        external
        returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    )
        external
        returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    function setAuthorization(address authorized, bool newIsAuthorized) external;
}
