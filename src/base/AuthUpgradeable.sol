// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { IAuthority } from "../interfaces/IAuthority.sol";

/// @title  AuthUpgradeable
/// @notice Upgradeable owner + pluggable authority. Storage-compatible with the deployed
///         `AuthUpgradeable` in `core` (same `auth.storage` ERC-7201 namespace + slot), so a V3
///         implementation can be deployed against an existing V2 proxy without storage drift.
/// @dev    Ported faithfully from `core/src/base/AuthUpgradeable.sol`. Only differences are the
///         pragma version and the use of the project-local `IAuthority` interface (same shape +
///         same ABI selector as solmate's `Authority`, so existing `RolesAuthority` deployments
///         drop in).
abstract contract AuthUpgradeable is Initializable {
    event OwnershipTransferred(address indexed user, address indexed newOwner);
    event AuthorityUpdated(address indexed user, IAuthority indexed newAuthority);

    error Unauthorized();

    /// @custom:storage-location erc7201:auth.storage
    struct AuthStorage {
        address owner;
        IAuthority authority;
    }

    // keccak256(abi.encode(uint256(keccak256("auth.storage")) - 1)) & ~bytes32(uint256(0xff))
    // solhint-disable-next-line const-name-snakecase
    bytes32 private constant AuthStorageLocation = 0xdd3fd67aef415aded9493b31ad20a02d2991d4bb2760431cc729821271eaea00;

    function _getAuthStorage() private pure returns (AuthStorage storage $) {
        assembly {
            $.slot := AuthStorageLocation
        }
    }

    function __Auth_init(address _owner, IAuthority _authority) internal onlyInitializing {
        AuthStorage storage $ = _getAuthStorage();
        $.owner = _owner;
        $.authority = _authority;
        emit OwnershipTransferred(msg.sender, _owner);
        emit AuthorityUpdated(msg.sender, _authority);
    }

    modifier requiresAuth() {
        if (!isAuthorized(msg.sender, msg.sig)) {
            revert Unauthorized();
        }
        _;
    }

    function isAuthorized(address user, bytes4 functionSig) public view virtual returns (bool) {
        AuthStorage storage $ = _getAuthStorage();
        IAuthority auth = $.authority;
        return (address(auth) != address(0) && auth.canCall(user, address(this), functionSig)) || user == $.owner;
    }

    function owner() public view virtual returns (address) {
        return _getAuthStorage().owner;
    }

    function authority() public view virtual returns (IAuthority) {
        return _getAuthStorage().authority;
    }

    /// @notice Replace the authority. Callable by the owner OR by a caller the current authority
    ///         allows for this exact selector. Owner-shortcircuit so they can always swap out a
    ///         broken / gas-heavy authority.
    function setAuthority(IAuthority newAuthority) public virtual {
        AuthStorage storage $ = _getAuthStorage();
        IAuthority auth = $.authority;
        bool ok =
            msg.sender == $.owner || (address(auth) != address(0) && auth.canCall(msg.sender, address(this), msg.sig));
        if (!ok) {
            revert Unauthorized();
        }
        $.authority = newAuthority;
        emit AuthorityUpdated(msg.sender, newAuthority);
    }

    function transferOwnership(address newOwner) public virtual requiresAuth {
        AuthStorage storage $ = _getAuthStorage();
        $.owner = newOwner;
        emit OwnershipTransferred(msg.sender, newOwner);
    }
}
