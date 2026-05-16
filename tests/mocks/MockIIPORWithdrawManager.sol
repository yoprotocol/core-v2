// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IIPORWithdrawManager } from "src/interfaces/external/IIPORWithdrawManager.sol";

/// @notice Mock of IPOR Fusion's per-PlasmaVault WithdrawManager. Faithful to the parts the
///         adapter + integration tests exercise:
///           - One-slot-per-account request mapping; second `requestShares` overwrites.
///           - Off-band `releaseFunds` keyed by a timestamp + a global `sharesToRelease` pool.
///           - `canWithdrawFromRequest` is mutating: atomically validates the claim window AND
///             decreases both the per-account `shares` and the global pool. Matches real IPOR.
///         Not modelled (irrelevant to adapter behavior): the `requestFee`/burn-fuse flow, the
///         `Atomist`-style access control, and the off-chain keeper allowlist.
contract MockIIPORWithdrawManager is IIPORWithdrawManager {
    uint32 public immutable withdrawWindow;
    uint256 public lastReleaseFundsTimestamp;
    uint256 public sharesToRelease;

    mapping(address account => WithdrawRequestInfo) internal _requests;

    error NoEligibleRequest();
    error ReleaseTimestampInFuture();

    constructor(uint32 _withdrawWindow) {
        withdrawWindow = _withdrawWindow;
    }

    /// @inheritdoc IIPORWithdrawManager
    function requestShares(uint256 shares) external override {
        _requests[msg.sender] = WithdrawRequestInfo({
            shares: uint128(shares),
            endWithdrawWindowTimestamp: uint32(block.timestamp) + withdrawWindow,
            canWithdraw: false,
            withdrawWindowInSeconds: withdrawWindow
        });
    }

    /// @notice IPOR keeper hook: marks `timestamp_` as the latest release and grows the redeemable
    ///         pool. In real IPOR this is `restricted` to the alpha role; we leave it open here so
    ///         tests can drive the state.
    function releaseFunds(uint256 timestamp_, uint256 amount_) external {
        if (timestamp_ > block.timestamp) {
            revert ReleaseTimestampInFuture();
        }
        lastReleaseFundsTimestamp = timestamp_;
        sharesToRelease += amount_;
    }

    /// @notice Mutating eligibility check called by `PlasmaVault.redeemFromRequest`. Reverts when
    ///         the request is missing / outside its claim window / the keeper has not released
    ///         covering funds yet, otherwise decrements both the per-account slot and the global
    ///         pool and returns true.
    function canWithdrawFromRequest(address owner, uint256 shares) external returns (bool) {
        // Single SLOAD: the struct (uint128 + uint32 + bool + uint32) packs into one slot.
        WithdrawRequestInfo memory r = _requests[owner];

        uint256 requestTimestamp =
            uint256(r.endWithdrawWindowTimestamp) - uint256(r.withdrawWindowInSeconds);

        bool ok = r.shares >= shares
            && block.timestamp >= requestTimestamp
            && block.timestamp <= r.endWithdrawWindowTimestamp
            && requestTimestamp < lastReleaseFundsTimestamp
            && sharesToRelease >= shares;

        if (!ok) {
            revert NoEligibleRequest();
        }

        _requests[owner].shares = uint128(uint256(r.shares) - shares);
        sharesToRelease -= shares;
        return true;
    }

    /// @inheritdoc IIPORWithdrawManager
    function requestInfo(address account) external view returns (WithdrawRequestInfo memory) {
        return _requests[account];
    }

    /// @inheritdoc IIPORWithdrawManager
    function getLastReleaseFundsTimestamp() external view returns (uint256) {
        return lastReleaseFundsTimestamp;
    }
}
