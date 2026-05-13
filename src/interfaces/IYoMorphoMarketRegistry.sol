// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "./IMorpho.sol";

/// @notice Per-vault allowlist of Morpho Blue markets reachable through `YoMorphoAdapter`.
interface IYoMorphoMarketRegistry {
    event MarketAllowed(address indexed vault, Id indexed marketId, bool allowed);

    error ZeroAddress();

    function setAllowed(address vault, Id marketId, bool allowed) external;

    function isAllowed(address vault, Id marketId) external view returns (bool);
}
