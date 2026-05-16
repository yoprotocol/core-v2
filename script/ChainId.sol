// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.9.0;

/// @notice Named chain-ID constants. Lifted from Sablier; trimmed to the set we currently deploy
///         on. Add new entries here when expanding to a new chain.
library ChainId {
    uint256 internal constant ARBITRUM = 42_161;
    uint256 internal constant BASE = 8453;
    uint256 internal constant ETHEREUM = 1;
    uint256 internal constant HYPEREVM = 999;
    uint256 internal constant KATANA = 747_474;
    uint256 internal constant MONAD = 143;
    uint256 internal constant OPTIMISM = 10;
    uint256 internal constant PLASMA = 9745;
    uint256 internal constant UNICHAIN = 130;
    uint256 internal constant XLAYER = 196;
}
