// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice NAV oracle used by the vault to derive `totalAssets()` from `totalSupply * sharePrice`.
/// @dev    Ported from `core/src/interfaces/IYoOracle.sol`. Distinct from `IYoSwapOracle` — this is
///         the per-vault share-price feed updated by the protocol's price-publisher.
interface IYoOracle {
    struct AssetOracleData {
        uint256 latestPrice;
        uint256 anchorPrice;
        uint64 anchorTimestamp;
        uint64 latestTimestamp;
        uint64 windowSeconds;
        uint64 maxChangeBps;
    }

    error NotUpdater();
    error InvalidConfig();
    error PriceChangeTooBig(
        address vault, uint256 newPrice, uint256 anchorPrice, uint256 diffBps, uint256 maxChangeBps
    );

    event UpdaterChanged(address indexed oldUpdater, address indexed newUpdater);
    event SharePriceUpdated(address indexed vault, uint256 price, uint64 timestamp);
    event AssetConfigUpdated(address indexed vault, uint32 windowSeconds, uint32 maxChangeBps);

    function getLatestPrice(address _vault) external view returns (uint256 sharePrice, uint64 timestamp);
}
