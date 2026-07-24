// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Per-vault allowlist and economic guardrails for Morpho Midnight markets reachable through
///         `YoMidnightAdapter`. Beyond a boolean allow flag, each market carries a `minTick` price
///         floor: the lowest offer tick the adapter will ratify (vault sell offers) or fill
///         (`takeSell`). Because Midnight's `TickLib.tickToPrice` is monotonic in tick, a tick floor
///         is a price floor — it bounds how cheaply a compromised operator can make the vault part
///         with credit, the Midnight analogue of `YoSwapPairRegistry`'s oracle-checked slippage floor.
interface IYoMidnightMarketRegistry {
    /// @param minTick Sell-side price floor as a Midnight tick; meaningful only while `allowed` is true.
    event MarketAllowed(address indexed vault, bytes32 indexed marketId, bool allowed, uint32 minTick);

    error ZeroAddress();

    /// @notice Allow or disallow `marketId` for `vault`, setting the sell-side price floor `minTick`.
    /// @dev    The floor is chosen at enable time (not a separate optional knob) so a market cannot be
    ///         allowlisted without an explicit price floor.
    function setAllowed(address vault, bytes32 marketId, bool allowed, uint32 minTick) external;

    /// @notice Whether `marketId` is reachable by `vault`.
    function isAllowed(address vault, bytes32 marketId) external view returns (bool);

    /// @notice Sell-side tick floor for `vault`'s `marketId` (0 when unset or disallowed).
    function minTickOf(address vault, bytes32 marketId) external view returns (uint32);
}
