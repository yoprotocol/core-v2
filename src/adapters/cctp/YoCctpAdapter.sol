// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ITokenMessengerV2 } from "../../interfaces/external/ITokenMessengerV2.sol";
import { IYoBridgeRouteRegistry } from "../../interfaces/IYoBridgeRouteRegistry.sol";
import { IYoCctpAdapter } from "../../interfaces/IYoCctpAdapter.sol";
import { IYoRegistry } from "../../interfaces/IYoRegistry.sol";
import { YoAdapterBase } from "../base/YoAdapterBase.sol";

/// @title  YoCctpAdapter
/// @notice Immutable adapter for Circle CCTP V2 native-USDC burn-and-mint transfers. See
///         `IYoCctpAdapter` for the approval / route contract.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`.
///           - The burn token is pinned to `usdc` at construction; nothing else can be bridged.
///           - Funds may only leave to a route allowlisted in `routeRegistry`.
///           - Each call leaks zero new balance / zero allowance to the `TokenMessenger`;
///             pre-existing dust is recoverable by registered YO vaults via `rescue` / `rescueETH`
///             (see {YoAdapterBase}).
contract YoCctpAdapter is YoAdapterBase, IYoCctpAdapter {
    using SafeERC20 for IERC20;

    /// @notice The CCTP V2 `TokenMessenger` this adapter burns through.
    ITokenMessengerV2 public immutable tokenMessenger;

    /// @notice The USDC token burned on this chain. Pinned at construction.
    IERC20 public immutable usdc;

    /// @notice Allowlist of permitted `(vault, adapter, usdc, destinationDomain, mintRecipient)` routes.
    IYoBridgeRouteRegistry public immutable routeRegistry;

    /// @notice Max fast-transfer fee tolerated, in bps of `amount`. Caps the operator's `maxFee`.
    uint256 public immutable maxFeeBps;

    constructor(
        ITokenMessengerV2 _tokenMessenger,
        IERC20 _usdc,
        IYoBridgeRouteRegistry _routeRegistry,
        uint256 _maxFeeBps,
        IYoRegistry _yoRegistry
    )
        YoAdapterBase(_yoRegistry)
    {
        tokenMessenger = _tokenMessenger;
        usdc = _usdc;
        routeRegistry = _routeRegistry;
        maxFeeBps = _maxFeeBps;
    }

    /// @inheritdoc IYoCctpAdapter
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold
    )
        external
        nonReentrant
        returns (uint256)
    {
        if (amount == 0) {
            revert InvalidAmount();
        }
        // Cap the fast-transfer fee. Circle deducts up to `maxFee` from the minted amount, so a
        // fat-fingered or malicious `maxFee` (up to `amount`) could burn most of the transfer as fees.
        // Not an operator skim (the fee accrues to Circle), but bounded for parity with the other
        // adapters' fee/slippage caps. `maxFee` is a ceiling; Circle charges the lower actual fee.
        uint256 feeCap = _applyBps(amount, maxFeeBps);
        if (maxFee > feeCap) {
            revert FeeTooHigh(maxFee, feeCap);
        }
        address vault = msg.sender;
        // CCTP mints USDC on the destination, so no output token is pinned (`bytes32(0)`).
        if (!routeRegistry.isRouteAllowed(
                vault, address(this), address(usdc), destinationDomain, mintRecipient, bytes32(0)
            )) {
            revert RouteNotAllowed(destinationDomain, mintRecipient);
        }

        usdc.safeTransferFrom(vault, address(this), amount);
        usdc.forceApprove(address(tokenMessenger), amount);

        // `destinationCaller` is forced to `bytes32(0)`: any address may complete the mint on the
        // destination, so a malicious operator cannot strand the burned USDC behind a dead caller
        // (CCTP has no expiry-refund). The recipient is already pinned by the route.
        tokenMessenger.depositForBurn(
            amount, destinationDomain, mintRecipient, address(usdc), bytes32(0), maxFee, minFinalityThreshold
        );

        usdc.forceApprove(address(tokenMessenger), 0);

        _emitAction(address(tokenMessenger), address(usdc), AdapterDirection.Bridge, amount);
        return amount;
    }
}
