// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IAggregatorV3 } from "./../interfaces/external/IAggregatorV3.sol";
import { IYoSwapOracle } from "./../interfaces/IYoSwapOracle.sol";

/// @title  YoChainlinkOracle
/// @notice `IYoSwapOracle` implementation backed by Chainlink USD aggregators. Each asset is
///         configured with one aggregator + heartbeat; quotes are 1e18-scaled USD prices.
/// @dev    Future oracle variants (e.g. `YoChainlinkTwapOracle` for composite cross-validation, or
///         a dedicated YO oracle) implement the same `IYoSwapOracle` interface and slot in as
///         drop-in replacements without changes to adapters.
///
///         Quote derivation for `getQuote(tokenIn, tokenOut, amountIn)`:
///           amountOut = amountIn * pIn * 10^outDec / (pOut * 10^inDec)
///         where pIn / pOut are 1e18-scaled USD prices and decimals are cached at config time.
contract YoChainlinkOracle is Ownable2Step, IYoSwapOracle {
    /*//////////////////////////////////////////////////////////////////////////
                                       TYPES
    //////////////////////////////////////////////////////////////////////////*/

    struct AssetConfig {
        address feed;
        uint32 heartbeat;
        uint8 assetDecimals;
        uint8 feedDecimals;
    }

    /// @dev Upper bound on cached `IERC20Metadata.decimals()`. Keeps `10**assetDecimals` well below
    ///      `type(uint128).max`; downstream math cannot overflow.
    uint8 internal constant MAX_DECIMALS = 38;

    /*//////////////////////////////////////////////////////////////////////////
                                       EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event AssetConfigSet(address indexed asset, address indexed feed, uint32 heartbeat);

    /*//////////////////////////////////////////////////////////////////////////
                                       ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    error UnknownAsset(address asset);
    error InvalidPrice(address asset);
    error ZeroOwner();
    error ZeroAsset();
    error ZeroHeartbeat();
    error DecimalsTooHigh(uint8 decimals);

    /*//////////////////////////////////////////////////////////////////////////
                                      STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    mapping(address asset => AssetConfig config) private _configs;

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) {
            revert ZeroOwner();
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  ADMIN API
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Configure (or remove) the Chainlink feed for `asset`. Owner-only.
    /// @dev    Pass `feed = address(0)` to clear the entry. Caches `assetDecimals` and
    ///         `feedDecimals` so the hot path needs no extra view calls.
    function setAssetConfig(address asset, address feed, uint32 heartbeat) external onlyOwner {
        if (asset == address(0)) {
            revert ZeroAsset();
        }

        if (feed == address(0)) {
            delete _configs[asset];
            emit AssetConfigSet(asset, address(0), 0);
            return;
        }

        if (heartbeat == 0) {
            revert ZeroHeartbeat();
        }

        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        if (assetDecimals > MAX_DECIMALS) {
            revert DecimalsTooHigh(assetDecimals);
        }

        _configs[asset] = AssetConfig({
            feed: feed,
            heartbeat: heartbeat,
            assetDecimals: assetDecimals,
            feedDecimals: IAggregatorV3(feed).decimals()
        });
        emit AssetConfigSet(asset, feed, heartbeat);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     VIEW API
    //////////////////////////////////////////////////////////////////////////*/

    function config(address asset) external view returns (AssetConfig memory) {
        return _configs[asset];
    }

    /// @notice Return the 1e18-scaled USD price of one whole unit of `asset`.
    function getPriceUSD(address asset) external view returns (uint256) {
        AssetConfig memory cfg = _configs[asset];
        if (cfg.feed == address(0)) {
            revert UnknownAsset(asset);
        }
        return _price(asset, cfg);
    }

    /// @inheritdoc IYoSwapOracle
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut) {
        AssetConfig memory cfgIn = _configs[tokenIn];
        AssetConfig memory cfgOut = _configs[tokenOut];
        if (cfgIn.feed == address(0) || cfgOut.feed == address(0)) {
            revert UnknownPair(tokenIn, tokenOut);
        }

        uint256 pIn = _price(tokenIn, cfgIn);
        uint256 pOut = _price(tokenOut, cfgOut);

        // amountOut = amountIn * pIn * 10^outDec / (pOut * 10^inDec)
        uint256 numerator = amountIn * pIn;
        if (cfgOut.assetDecimals >= cfgIn.assetDecimals) {
            uint256 scale = 10 ** uint256(cfgOut.assetDecimals - cfgIn.assetDecimals);
            amountOut = Math.mulDiv(numerator, scale, pOut);
        } else {
            uint256 scale = 10 ** uint256(cfgIn.assetDecimals - cfgOut.assetDecimals);
            amountOut = Math.mulDiv(numerator, 1, pOut * scale);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  INTERNAL
    //////////////////////////////////////////////////////////////////////////*/

    function _price(address asset, AssetConfig memory cfg) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(cfg.feed).latestRoundData();
        if (answer <= 0) {
            revert InvalidPrice(asset);
        }
        // Reject prices from rounds that did not reach Chainlink consensus.
        if (answeredInRound < roundId) {
            revert StalePrice(asset);
        }
        // Forward-skewed `updatedAt` would otherwise underflow the subtraction; fail closed.
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > cfg.heartbeat) {
            revert StalePrice(asset);
        }
        return _scaleToE18(uint256(answer), cfg.feedDecimals);
    }

    function _scaleToE18(uint256 value, uint8 fromDec) internal pure returns (uint256) {
        if (fromDec == 18) {
            return value;
        }
        if (fromDec < 18) {
            return value * (10 ** uint256(18 - fromDec));
        }
        return value / (10 ** uint256(fromDec - 18));
    }
}
