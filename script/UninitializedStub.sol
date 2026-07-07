// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

/// @notice Inert first implementation for cross-chain deterministic proxy deploys. It has no
///         initializer and no fallback, so the proxy cannot be initialized (hijacked) by anyone
///         between its deployment and the `upgradeAndCall` that installs the real implementation.
contract UninitializedStub {
    /// @notice State-free no-op. OZ 5.6+ proxies refuse empty constructor init data, so the proxy
    ///         is constructed with a delegatecall to this instead.
    function ping() external { }
}
