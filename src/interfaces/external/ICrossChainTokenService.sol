// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal interface for Circle's "CCTP for non-USDC" (CCTPx) `CrossChainTokenService`, the
///         origin-chain entrypoint for burn-and-mint transfers of non-USDC tokens such as EURC.
/// @dev    CCTPx rides on CCTP V2's `MessageTransmitterV2` and Iris attestations, but it is a separate
///         contract layer from `TokenMessengerV2`:
///           - Tokens are addressed by a cross-chain `tokenId`, not by address.
///           - The per-token `TokenManager` (`resolveTokenManager(tokenId)`) pulls the tokens, so it —
///             not the service — is the approval spender.
///           - Fees are paid upfront in the native gas asset against a signed Iris quote; the recipient
///             receives the full `amount`.
///         Domains are Circle-internal ids, NOT EVM chain ids (domain 0 = Ethereum, domain 6 = Base).
interface ICrossChainTokenService {
    /// @notice Signed fee quote plus the refund attribution address, forwarded verbatim to the fee
    ///         manager. ABI-identical to Circle's `IFeeManager.QuoteClaim`.
    /// @param signedQuote   Version-prefixed, ABI-encoded quote returned by the Iris quote API.
    /// @param refundAddress Address any fee refund is attributed to. Not part of the signed quote.
    struct QuoteClaim {
        bytes signedQuote;
        address payable refundAddress;
    }

    /// @notice Burn `amount` of the `tokenId` token for delivery to `destinationAddress` on
    ///         `destinationDomain`, paying the quoted fee from `msg.value`.
    /// @param tokenId              Cross-chain id of the token to transfer.
    /// @param amount               Amount to transfer, in the local token's decimals.
    /// @param destinationDomain    Circle domain id of the destination chain.
    /// @param destinationAddress   Recipient on the destination domain. On EVM it must be the raw
    ///                             20-byte address; any other length makes delivery revert.
    /// @param destinationCaller    Address allowed to relay the message on the destination, as
    ///                             `bytes32`; `bytes32(0)` permits any caller.
    /// @param minFinalityThreshold `2000` selects a standard transfer, `1000` a fast transfer.
    /// @param claim                Signed fee quote and refund address.
    /// @param autoExecuteHookData  Whether `hookData` is executed on the recipient at delivery.
    /// @param hookData             Optional destination hook payload.
    function crossChainTransfer(
        bytes32 tokenId,
        uint256 amount,
        uint32 destinationDomain,
        bytes calldata destinationAddress,
        bytes32 destinationCaller,
        uint32 minFinalityThreshold,
        QuoteClaim calldata claim,
        bool autoExecuteHookData,
        bytes calldata hookData
    )
        external
        payable;

    /// @notice The deployed `TokenManager` for `tokenId`. Reverts `TokenNotRegistered` if none.
    function resolveTokenManager(bytes32 tokenId) external view returns (address);

    /// @notice The local token managed for `tokenId`. Reverts `TokenNotRegistered` if none.
    function resolveTokenAddress(bytes32 tokenId) external view returns (address);

    /// @notice The fee manager that collects quoted fees.
    function feeService() external view returns (address);
}
