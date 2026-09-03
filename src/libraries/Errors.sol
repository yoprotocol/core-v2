// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title  Errors
/// @notice Centralized error library shared across YO contracts. Ported from
///         `core/src/libraries/Errors.sol`. Names and arg types match exactly so revert selectors
///         (`bytes4(keccak256("ErrorName(types)"))`) are identical to V2 — external integrators
///         decoding reverts see the same data across the V2 → V3 upgrade.
library Errors {
    /*//////////////////////////////////////////////////////////////////////////
                                    GENERIC / VAULT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an unauthorized method to a target is called.
    /// @dev    The method must be authorized by `setUserRole` and `setRoleCapability` on the
    ///         `RolesAuthority` wired to the vault.
    error TargetMethodNotAuthorized(address target, bytes4 functionSig);

    /// @notice Thrown when insufficient shares balance is available to complete the operation.
    error InsufficientShares();

    /// @notice Thrown when the operation is called by a user that is not the owner of the shares.
    error NotSharesOwner();

    /// @notice Thrown when the input shares amount is zero.
    error SharesAmountZero();

    /// @notice Thrown when a claim request is fulfilled with an invalid shares amount.
    error InvalidSharesAmount();

    /// @notice Thrown when a fulfilment slice's gross value rounds to zero.
    /// @dev Same selector as the V2 error of this name, so existing revert decoders stay valid.
    error InvalidAssetsAmount();

    /// @notice Thrown when the new max percentage is greater than the current max percentage.
    error InvalidMaxPercentage();

    /// @notice Thrown when the new fee is greater than the max allowed fee.
    error InvalidFee();

    /// @notice Thrown when the underlying balance has already been updated in the current block.
    error UpdateAlreadyCompletedInThisBlock();

    /// @notice Thrown when `redeem()` or `withdraw()` is called directly (use `requestRedeem`).
    error UseRequestRedeem();

    error UseOnSharePriceUpdate();

    /// @notice Thrown when the price is zero.
    error InvalidPrice();

    /// @notice Thrown when the receiver is zero.
    error ZeroReceiver();

    /// @notice Thrown when the redemption receiver is the vault itself; cancel would strand the shares.
    error SelfReceiverNotAllowed();

    /// @notice Thrown when a current-price fulfilment is attempted while the current price is
    ///         above the request price: the entry's current value exceeds its reserved value.
    error CurrentPriceAboveRequestPrice(uint256 currentValue, uint256 reservedValue);

    /*//////////////////////////////////////////////////////////////////////////
                                       ESCROW
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when `msg.sender` is not the vault.
    error Escrow__OnlyVault();

    /// @notice Thrown when the requested amount of assets is zero.
    error Escrow__AmountZero();

    /*//////////////////////////////////////////////////////////////////////////
                                      REGISTRY
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the vault address is zero.
    error Registry__VaultAddressZero();

    /// @notice Thrown when the vault already exists.
    error Registry__VaultAlreadyExists(address vaultAddress);

    /// @notice Thrown when the vault does not exist.
    error Registry__VaultNotExists(address vaultAddress);

    /*//////////////////////////////////////////////////////////////////////////
                                       GATEWAY
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the vault is not allowed.
    error Gateway__VaultNotAllowed();

    /// @notice Thrown when the amount is zero.
    error Gateway__ZeroAmount();

    /// @notice Thrown when the receiver is zero.
    error Gateway__ZeroReceiver();

    /// @notice Thrown when the shares out is less than the minimum shares out.
    error Gateway__InsufficientSharesOut(uint256 sharesOut, uint256 minSharesOut);

    /// @notice Thrown when the owner of the shares is zero.
    error Gateway__ZeroOwner();

    /// @notice Thrown when the assets out is less than the minimum assets out.
    error Gateway__InsufficientAssetsOut(uint256 assetsOut, uint256 minAssetsOut);
}
