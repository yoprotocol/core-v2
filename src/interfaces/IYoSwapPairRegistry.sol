// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Per-vault allowlist of swap pairs reachable through swap adapters.
/// @dev    Each `(vault, tokenIn, tokenOut)` carries a `PairMode` that tells the adapter what
///         on-chain checks to apply:
///           - `DISALLOWED`       — pair cannot be swapped.
///           - `ORACLE_CHECKED`   — adapter consults the oracle and enforces a slippage floor.
///           - `OPERATOR_TRUSTED` — adapter SKIPS the oracle floor; the operator's `minOut` is the
///                                  only on-chain constraint. Use for exotic assets without a
///                                  reliable price feed where the cosigner is the only check.
///         Direction matters: `(A, B)` does not imply `(B, A)`.
interface IYoSwapPairRegistry {
    enum PairMode {
        DISALLOWED,
        ORACLE_CHECKED,
        OPERATOR_TRUSTED
    }

    event PairModeSet(address indexed vault, address indexed tokenIn, address indexed tokenOut, PairMode mode);

    error ZeroAddress();
    error SameToken(address token);

    /// @notice Set the swap mode for a pair. Owner-only.
    function setMode(address vault, address tokenIn, address tokenOut, PairMode mode) external;

    /// @notice Return the swap mode for a pair. Defaults to `DISALLOWED`.
    function modeOf(address vault, address tokenIn, address tokenOut) external view returns (PairMode);

    /// @notice Convenience: true if `mode != DISALLOWED`. Adapters should consult `modeOf` directly
    ///         because they need to branch on the specific mode.
    function isAllowed(address vault, address tokenIn, address tokenOut) external view returns (bool);
}
