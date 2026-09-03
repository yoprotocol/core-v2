// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title  IYoVault
/// @notice Interface for the YO vault. V3 extends V2's surface with two operator-safety methods
///         (`approveToken`, `setApprovalRegistry`) and their events/errors. Existing V2 events
///         and the `PendingRedeem` struct are preserved verbatim for ABI compatibility with the
///         on-chain V2 proxy.
interface IYoVault {
    /*//////////////////////////////////////////////////////////////////////////
                                       TYPES
    //////////////////////////////////////////////////////////////////////////*/

    struct PendingRedeem {
        uint256 assets;
        uint256 shares;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  V2 EVENTS (KEPT)
    //////////////////////////////////////////////////////////////////////////*/

    event WithdrawFeeUpdated(uint256 lastFee, uint256 newFee);
    event DepositFeeUpdated(uint256 lastFee, uint256 newFee);
    event FeeRecipientUpdated(address lastFeeRecipient, address newFeeRecipient);
    event MaxPercentageUpdated(uint256 lastMaxPercentage, uint256 newMaxPercentage);
    event UnderlyingBalanceUpdated(uint256 lastUnderlyingBalance, uint256 newUnderlyingBalance);
    event RedeemRequest(
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares,
        bool indexed instant
    );
    /// @dev `assets` is the gross paid, which a current-price fulfilment can set below the
    ///      reservation released for `shares`.
    event RequestFulfilled(address indexed receiver, uint256 shares, uint256 assets);
    event RequestCancelled(address indexed receiver, uint256 shares, uint256 assets);

    /*//////////////////////////////////////////////////////////////////////////
                                  V3 ADDITIONS
    //////////////////////////////////////////////////////////////////////////*/

    event ApprovalRegistrySet(address indexed previous, address indexed current);

    /// @notice `approveToken` rejected because `(token, spender)` is not allowlisted (cap == 0).
    error SpenderNotAllowed(address token, address spender);

    /// @notice `approveToken` rejected because the requested amount exceeds the registry cap.
    error AmountExceedsCap(uint256 requested, uint256 cap);

    /// @notice `approveToken` called while the approval registry is unconfigured.
    error ApprovalRegistryUnset();

    /*//////////////////////////////////////////////////////////////////////////
                                  V2 SURFACE (KEPT)
    //////////////////////////////////////////////////////////////////////////*/

    function requestRedeem(uint256 shares, address receiver, address owner) external returns (uint256 requestId);
}
