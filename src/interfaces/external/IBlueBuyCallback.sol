// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Subset of Morpho's `BlueBuyCallback` used by `YoMidnightAdapter`. Inlined because the
///         upstream interface imports Morpho Blue from a git submodule.
/// @dev    Source of truth: morpho-org/midnight, file
///         `src/periphery/blue-buy-callback/interfaces/IBlueBuyCallback.sol`.
interface IBlueBuyCallback {
    /// @notice The account whose buy offers this callback funds, and who may withdraw its Blue positions.
    function OWNER() external view returns (address);
}
