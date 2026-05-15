// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Subset of Lido's `WithdrawalQueueERC721` interface used by `YoLidoAdapter`.
/// @dev    Source of truth:
/// https://github.com/lidofinance/lido-dao/blob/master/contracts/0.8.9/WithdrawalQueueERC721.sol Combines the queue
/// methods we need (`requestWithdrawals`, `claimWithdrawal`) with the
///         minimal ERC-721 surface (`ownerOf`, `transferFrom`, `setApprovalForAll`).
interface IWithdrawalQueueERC721 {
    /// @notice Submit one or more withdrawal requests. Pulls `sum(amounts)` stETH from `msg.sender`
    ///         and mints one ERC-721 receipt to `owner` per request.
    function requestWithdrawals(
        uint256[] calldata amounts,
        address owner
    )
        external
        returns (uint256[] memory requestIds);

    /// @notice Burn a finalized withdrawal receipt and send the redeemed ETH to `msg.sender`.
    /// @dev    Caller MUST be the current owner of the receipt NFT.
    function claimWithdrawal(uint256 requestId) external;

    // ERC-721 subset.
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}
