// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title  Compatible
/// @notice Abstract contract that allows the vault to receive ether and ERC-721/1155 tokens.
/// @dev    Ported verbatim from `core/src/base/Compatible.sol` so V3 stays binary-storage-compatible
///         and inherits the same callback surface as V2.
abstract contract Compatible {
    /// @notice Emitted when the contract receives ether.
    event Received(address sender, uint256 amount);

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    )
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
