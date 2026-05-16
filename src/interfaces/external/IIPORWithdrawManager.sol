// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal interface for IPOR Fusion's per-PlasmaVault `WithdrawManager`. Used by YO vaults
///         to encode the async-redemption request via `YoVault.manage(...)`; the adapter never
///         calls this contract.
/// @dev    The request slot is `mapping(address account => WithdrawRequest)`, keyed by
///         `_msgSender()` to `requestShares`. This is why YO vaults call this contract directly
///         (not via the adapter) — the request must be keyed to the vault, not to a shared adapter,
///         otherwise multiple YO vaults sharing one IPOR target would overwrite each other's slots.
///
///         If `WithdrawManager.requestFee > 0`, the holder must approve the WithdrawManager on the
///         PlasmaVault's share token before calling `requestShares`.
interface IIPORWithdrawManager {
    struct WithdrawRequestInfo {
        uint128 shares;
        uint32 endWithdrawWindowTimestamp;
        bool canWithdraw;
        uint32 withdrawWindowInSeconds;
    }

    /// @notice Queue an async redemption of `shares` keyed to `msg.sender`. Overwrites any prior
    ///         pending request for the same caller.
    function requestShares(uint256 shares) external;

    /// @notice Inspect the pending request for `account`. Returns zero-valued fields if no request.
    function requestInfo(address account) external view returns (WithdrawRequestInfo memory);

    /// @notice Last timestamp at which the IPOR keeper released funds. Compare against the request
    ///         timestamp (= `endWithdrawWindowTimestamp - withdrawWindowInSeconds`) to determine
    ///         whether a claim is currently eligible.
    function getLastReleaseFundsTimestamp() external view returns (uint256);
}
