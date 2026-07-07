// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IYoBridgeRouteRegistry } from "../interfaces/IYoBridgeRouteRegistry.sol";

/// @title  YoBridgeRouteRegistry
/// @notice Per-vault allowlist of cross-chain destinations reachable through the YO bridge adapters.
///         See `IYoBridgeRouteRegistry` for the route-key rationale.
/// @dev    `recipient` is intentionally NOT zero-checked: some bridges treat `bytes32(0)` as a
///         meaningful sentinel, and an unset route already defaults to disallowed, so a zero
///         recipient cannot widen access.
contract YoBridgeRouteRegistry is Ownable2Step, IYoBridgeRouteRegistry {
    /// @dev Allowlist keyed by a hash of the route tuple (see `_routeId`). A single hashed key keeps
    ///      the storage flat and readable instead of a five-level nested mapping.
    mapping(bytes32 routeId => bool allowed) private _routes;

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) {
            revert ZeroAddress();
        }
    }

    /// @inheritdoc IYoBridgeRouteRegistry
    function setRoute(
        address vault,
        address adapter,
        address token,
        uint256 destinationId,
        bytes32 recipient,
        bool allowed
    )
        external
        onlyOwner
    {
        if (vault == address(0) || adapter == address(0) || token == address(0)) {
            revert ZeroAddress();
        }
        _routes[_routeId(vault, adapter, token, destinationId, recipient)] = allowed;
        emit RouteSet(vault, adapter, token, destinationId, recipient, allowed);
    }

    /// @inheritdoc IYoBridgeRouteRegistry
    function isRouteAllowed(
        address vault,
        address adapter,
        address token,
        uint256 destinationId,
        bytes32 recipient
    )
        external
        view
        returns (bool)
    {
        return _routes[_routeId(vault, adapter, token, destinationId, recipient)];
    }

    /// @dev Hash of a route tuple, used as the `_routes` key. `abi.encode` (not `encodePacked`)
    ///      guarantees an unambiguous, collision-free encoding of the five fields.
    function _routeId(
        address vault,
        address adapter,
        address token,
        uint256 destinationId,
        bytes32 recipient
    )
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(vault, adapter, token, destinationId, recipient));
    }
}
