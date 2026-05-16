// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "./IMorpho.sol";

/// @notice Immutable adapter that brokers all Morpho Blue interactions on behalf of a vault.
interface IYoMorphoAdapter {
    error MarketNotAllowed(Id id);
    error UnknownMarket(Id id);
    error NoPosition(Id id);
    error InvalidAmount();
    error NoShareDelta();

    function supply(Id marketId, uint256 assets) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function withdraw(Id marketId, uint256 assets) external returns (uint256 assetsWithdrawn, uint256 sharesBurned);

    function withdrawAll(Id marketId) external returns (uint256 assetsWithdrawn, uint256 sharesBurned);
}
