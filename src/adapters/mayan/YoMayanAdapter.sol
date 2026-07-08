// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMayanForwarder } from "../../interfaces/external/IMayanForwarder.sol";
import { IMayanSwift } from "../../interfaces/external/IMayanSwift.sol";
import { IYoBridgeRouteRegistry } from "../../interfaces/IYoBridgeRouteRegistry.sol";
import { IYoMayanAdapter } from "../../interfaces/IYoMayanAdapter.sol";
import { IYoRegistry } from "../../interfaces/IYoRegistry.sol";
import { YoAdapterBase } from "../base/YoAdapterBase.sol";

/// @title  YoMayanAdapter
/// @notice Immutable adapter for Mayan Swift cross-chain orders (`forwardERC20` + swap-then-bridge).
///         See `IYoMayanAdapter` for the approval / decode / route contract.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`.
///           - Only Swift `createOrderWithToken` is accepted; the selector guard is fail-closed.
///           - The forwarded order's refund owner (`trader`) is the vault, it pays no referrer
///             (`referrerAddr`/`referrerBps` forced to zero), carries no `customPayload` (empty), and
///             its `(destChainId, destAddr)` is an allowlisted route — so neither the output, a
///             refund, nor a referral fee can be redirected off the vault, and no destination-side
///             payload can be attached.
///           - Each call leaks zero new balance / zero allowance to the Forwarder; pre-existing dust
///             is recoverable by registered YO vaults via `rescue` / `rescueETH` (see {YoAdapterBase}).
contract YoMayanAdapter is YoAdapterBase, IYoMayanAdapter {
    using SafeERC20 for IERC20;

    /// @notice The Mayan Forwarder this adapter forwards through.
    IMayanForwarder public immutable forwarder;

    /// @notice The single Mayan protocol (Swift) this adapter forwards to. Pinned at construction.
    address public immutable swiftProtocol;

    /// @notice Allowlist of permitted `(vault, adapter, tokenIn, destChainId, destAddr)` routes.
    IYoBridgeRouteRegistry public immutable routeRegistry;

    constructor(
        IMayanForwarder _forwarder,
        address _swiftProtocol,
        IYoBridgeRouteRegistry _routeRegistry,
        IYoRegistry _yoRegistry
    )
        YoAdapterBase(_yoRegistry)
    {
        forwarder = _forwarder;
        swiftProtocol = _swiftProtocol;
        routeRegistry = _routeRegistry;
    }

    /// @inheritdoc IYoMayanAdapter
    function forwardERC20(
        address tokenIn,
        uint256 amountIn,
        bytes calldata protocolData
    )
        external
        nonReentrant
        returns (uint256)
    {
        if (amountIn == 0) {
            revert InvalidAmount();
        }

        (address orderTokenIn, uint256 orderAmountIn, IMayanSwift.OrderParams memory params) =
            _decodeOrder(protocolData);
        if (orderTokenIn != tokenIn || orderAmountIn != amountIn) {
            revert ProtocolDataMismatch();
        }
        _checkTraderAndRoute(msg.sender, tokenIn, params);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(forwarder), amountIn);

        IMayanForwarder.PermitParams memory noPermit;
        forwarder.forwardERC20(tokenIn, amountIn, noPermit, swiftProtocol, protocolData);

        IERC20(tokenIn).forceApprove(address(forwarder), 0);

        _emitAction(address(forwarder), tokenIn, AdapterDirection.Bridge, amountIn);
        return amountIn;
    }

    /// @inheritdoc IYoMayanAdapter
    function swapAndForwardERC20(SwapForwardParams calldata params) external nonReentrant returns (uint256) {
        if (params.amountIn == 0) {
            revert InvalidAmount();
        }

        // The Forwarder rewrites the order amount with the swap output, so only the order's input
        // token (which must equal the middle token) is checked, not its amount.
        (address orderTokenIn,, IMayanSwift.OrderParams memory order) = _decodeOrder(params.mayanData);
        if (orderTokenIn != params.middleToken) {
            revert ProtocolDataMismatch();
        }
        _checkTraderAndRoute(msg.sender, params.tokenIn, order);

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        IERC20(params.tokenIn).forceApprove(address(forwarder), params.amountIn);

        _forwardSwap(params);

        IERC20(params.tokenIn).forceApprove(address(forwarder), 0);

        _emitAction(address(forwarder), params.tokenIn, AdapterDirection.Bridge, params.amountIn);
        return params.amountIn;
    }

    /// @dev Forward the swap-then-bridge call. Isolated so the 9-argument external call stays within
    ///      the stack limit under the optimizer-off `lite` profile.
    function _forwardSwap(SwapForwardParams calldata params) private {
        IMayanForwarder.PermitParams memory noPermit;
        forwarder.swapAndForwardERC20(
            params.tokenIn,
            params.amountIn,
            noPermit,
            params.swapProtocol,
            params.swapData,
            params.middleToken,
            params.minMiddleAmount,
            swiftProtocol,
            params.mayanData
        );
    }

    /// @dev Decode Mayan data as a Swift V2 `createOrderWithToken` order, enforcing the selector
    ///      fail-closed. Returns the order's declared input token, amount, and params. The trailing
    ///      `customPayload` is decoded and required to be empty — only plain transfers are permitted,
    ///      never a destination-side payload/hook.
    function _decodeOrder(bytes calldata data)
        private
        pure
        returns (address orderTokenIn, uint256 orderAmountIn, IMayanSwift.OrderParams memory params)
    {
        if (data.length < 4 || bytes4(data) != IMayanSwift.createOrderWithToken.selector) {
            revert UnsupportedProtocolData(data.length < 4 ? bytes4(0) : bytes4(data));
        }
        bytes memory customPayload;
        (orderTokenIn, orderAmountIn, params, customPayload) =
            abi.decode(data[4:], (address, uint256, IMayanSwift.OrderParams, bytes));
        if (customPayload.length != 0) {
            revert CustomPayloadNotAllowed(customPayload.length);
        }
    }

    /// @dev Enforce the order's refund owner is the vault and its destination is an allowlisted route
    ///      (keyed on the vault's outgoing `routeToken`).
    function _checkTraderAndRoute(
        address vault,
        address routeToken,
        IMayanSwift.OrderParams memory params
    )
        private
        view
    {
        if (params.trader != bytes32(uint256(uint160(vault)))) {
            revert TraderNotVault(params.trader);
        }
        // Forbid any referrer payout — Swift pays `referrerBps` of the fill to `referrerAddr` at
        // settlement, which would let an operator skim value to an arbitrary address.
        if (params.referrerBps != 0 || params.referrerAddr != bytes32(0)) {
            revert ReferrerNotAllowed(params.referrerAddr, params.referrerBps);
        }
        if (!routeRegistry.isRouteAllowed(vault, address(this), routeToken, params.destChainId, params.destAddr)) {
            revert RouteNotAllowed(routeToken, params.destChainId, params.destAddr);
        }
    }
}
