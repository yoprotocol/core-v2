// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Per-vault allowlist of cross-chain destinations reachable through the YO bridge adapters
///         (`YoAcrossAdapter`, `YoCcipAdapter`, `YoCctpAdapter`).
/// @dev    Bridges are the only adapters that move value OFF the current chain to a recipient
///         elsewhere, so the usual "funds return to the vault" invariant does not apply. This
///         registry is the on-chain destination floor: an adapter may only let `vault` send `token`
///         to `(destinationId, recipient)` if the multisig has explicitly allowlisted that route.
///
///         A route is keyed on five fields:
///           - `vault`         — the calling YO vault.
///           - `adapter`       — the bridge adapter (`address(this)` inside the adapter). Namespaces
///                               routes per bridge so an Across route for chainId 8453 can never be
///                               reused as a CCTP route for domain 8453.
///           - `token`         — the asset leaving the chain (e.g. USDC).
///           - `destinationId` — the bridge's native destination identifier, widened to `uint256`
///                               (Across chainId, CCIP chain selector, CCTP domain).
///           - `recipient`     — the destination recipient, widened to `bytes32` (an EVM address is
///                               left-padded to 32 bytes).
interface IYoBridgeRouteRegistry {
    event RouteSet(
        address indexed vault,
        address indexed adapter,
        address indexed token,
        uint256 destinationId,
        bytes32 recipient,
        bool allowed
    );

    error ZeroAddress();
    error RenounceDisabled();

    /// @notice Allow or disallow a single bridge route. Owner-only.
    /// @param vault         The YO vault the route applies to.
    /// @param adapter       The bridge adapter that will consult this route.
    /// @param token         The asset being bridged.
    /// @param destinationId The bridge's destination identifier, widened to `uint256`.
    /// @param recipient     The destination recipient, widened to `bytes32`.
    /// @param allowed       `true` to allow the route, `false` to revoke it.
    function setRoute(
        address vault,
        address adapter,
        address token,
        uint256 destinationId,
        bytes32 recipient,
        bool allowed
    )
        external;

    /// @notice Whether `vault` may bridge `token` to `(destinationId, recipient)` via `adapter`.
    /// @dev    Defaults to `false` for every unset route.
    function isRouteAllowed(
        address vault,
        address adapter,
        address token,
        uint256 destinationId,
        bytes32 recipient
    )
        external
        view
        returns (bool);
}
