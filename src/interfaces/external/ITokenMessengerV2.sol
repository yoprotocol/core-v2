// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal interface for Circle's CCTP V2 `TokenMessengerV2`, the origin-chain entrypoint
///         for native USDC burn-and-mint transfers.
/// @dev    `depositForBurn` burns `amount` of `burnToken` on the source domain; Circle's attestation
///         service later authorizes a mint of the equivalent USDC to `mintRecipient` on
///         `destinationDomain`. CCTP domains are Circle-internal ids, NOT EVM chain ids (e.g. domain
///         0 = Ethereum, domain 6 = Base).
interface ITokenMessengerV2 {
    /// @notice Burn `amount` of `burnToken` for minting on `destinationDomain`.
    /// @param amount                Amount of `burnToken` to burn.
    /// @param destinationDomain     Circle domain id of the destination chain.
    /// @param mintRecipient         Recipient on the destination domain, as `bytes32` (an EVM
    ///                              address is left-padded to 32 bytes).
    /// @param burnToken             Token to burn on the source domain (USDC).
    /// @param destinationCaller     Address authorized to mint on the destination domain, as
    ///                              `bytes32`; `bytes32(0)` permits any caller.
    /// @param maxFee                Maximum fee (in `burnToken` units) deducted at mint time.
    /// @param minFinalityThreshold  Minimum finality before attestation: `<= 1000` selects Fast
    ///                              Transfer where supported, `2000` selects Standard.
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    )
        external;
}
