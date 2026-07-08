// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMayanForwarder } from "../../interfaces/external/IMayanForwarder.sol";
import { IMayanSwift } from "../../interfaces/external/IMayanSwift.sol";
import { IYoBridgeRouteRegistry } from "../../interfaces/IYoBridgeRouteRegistry.sol";
import { IYoMayanAdapter } from "../../interfaces/IYoMayanAdapter.sol";
import { IYoRegistry } from "../../interfaces/IYoRegistry.sol";
import { IYoSwapOracle } from "../../interfaces/IYoSwapOracle.sol";
import { IYoSwapPairRegistry } from "../../interfaces/IYoSwapPairRegistry.sol";
import { YoAdapterBase } from "../base/YoAdapterBase.sol";

/// @title  YoMayanAdapter
/// @notice Immutable adapter for Mayan Swift cross-chain orders (`forwardERC20` + swap-then-bridge).
///         See `IYoMayanAdapter` for the approval / decode / route contract.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`.
///           - Only Swift `createOrderWithToken` is accepted; the selector guard is fail-closed.
///           - The forwarded order's refund owner (`trader`) is the vault, it pays no referrer
///             (`referrerAddr`/`referrerBps` forced to zero), carries no `customPayload` (empty), and
///             its `(destChainId, destAddr, tokenOut)` is an allowlisted route (the destination token
///             is part of the route key) — so neither the output, its token, a refund, nor a referral
///             fee can be redirected off the vault, and no destination-side payload can be attached.
///           - `swapAndForwardERC20`'s source swap is oracle-floored via `YoSwapPairRegistry` +
///             `YoSwapOracle` + `maxSlippageBps`, so the operator cannot drain the vault through a
///             fake or underpriced middle token. The cross-chain `minAmountOut` remains
///             operator/cosigner-trusted (not floorable on the source chain).
///           - Each call leaks zero new balance / zero allowance to the Forwarder; pre-existing dust
///             is recoverable by registered YO vaults via `rescue` / `rescueETH` (see {YoAdapterBase}).
contract YoMayanAdapter is YoAdapterBase, IYoMayanAdapter {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Immutable construction config. A struct keeps the constructor within the ≤5-positional
    ///         convention while carrying both the bridge wiring and the swap-floor wiring.
    /// @param forwarder      Mayan Forwarder the adapter forwards through.
    /// @param swiftProtocol  The single Mayan protocol (Swift) the adapter targets.
    /// @param routeRegistry  Destination allowlist `(vault, adapter, tokenIn, destChainId, destAddr)`.
    /// @param oracle         Price oracle flooring the source-swap leg.
    /// @param pairRegistry   Per-vault swap-pair allowlist for the source-swap leg.
    /// @param maxSlippageBps Max slippage (bps) tolerated on an `ORACLE_CHECKED` source swap.
    /// @param yoRegistry     YO registry consulted for `rescue` auth (see {YoAdapterBase}).
    struct InitParams {
        IMayanForwarder forwarder;
        address swiftProtocol;
        IYoBridgeRouteRegistry routeRegistry;
        IYoSwapOracle oracle;
        IYoSwapPairRegistry pairRegistry;
        uint256 maxSlippageBps;
        IYoRegistry yoRegistry;
    }

    /// @notice The Mayan Forwarder this adapter forwards through.
    IMayanForwarder public immutable forwarder;

    /// @notice The single Mayan protocol (Swift) this adapter forwards to. Pinned at construction.
    address public immutable swiftProtocol;

    /// @notice Allowlist of permitted `(vault, adapter, tokenIn, destChainId, destAddr)` routes.
    IYoBridgeRouteRegistry public immutable routeRegistry;

    /// @notice Oracle flooring the source-swap leg of `swapAndForwardERC20`.
    IYoSwapOracle public immutable oracle;

    /// @notice Per-vault swap-pair allowlist governing the source-swap leg.
    IYoSwapPairRegistry public immutable pairRegistry;

    /// @notice Max slippage (bps) tolerated on an `ORACLE_CHECKED` source swap.
    uint256 public immutable maxSlippageBps;

    constructor(InitParams memory p) YoAdapterBase(p.yoRegistry) {
        forwarder = p.forwarder;
        swiftProtocol = p.swiftProtocol;
        routeRegistry = p.routeRegistry;
        oracle = p.oracle;
        pairRegistry = p.pairRegistry;
        maxSlippageBps = p.maxSlippageBps;
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
        _checkSwapFloor(msg.sender, params.tokenIn, params.middleToken, params.amountIn, params.minMiddleAmount);

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

    /// @dev Floor the source-swap leg exactly as `YoSwapAdapter` does: the `(tokenIn, middleToken)`
    ///      pair must be allowlisted, and when `ORACLE_CHECKED` the operator's `minMiddleAmount` must
    ///      clear the oracle quote less `maxSlippageBps`. This pins both the middle-token identity
    ///      (an attacker-controlled fake token has no allowlisted pair / oracle feed) and its fair
    ///      value, so the swap cannot be used to divert the vault's funds. `OPERATOR_TRUSTED` pairs
    ///      skip the oracle for exotic assets the multisig has explicitly opted into.
    function _checkSwapFloor(
        address vault,
        address tokenIn,
        address middleToken,
        uint256 amountIn,
        uint256 minMiddleAmount
    )
        private
        view
    {
        IYoSwapPairRegistry.PairMode mode = pairRegistry.modeOf(vault, tokenIn, middleToken);
        if (mode == IYoSwapPairRegistry.PairMode.DISALLOWED) {
            revert PairNotAllowed(tokenIn, middleToken);
        }
        if (mode == IYoSwapPairRegistry.PairMode.ORACLE_CHECKED) {
            uint256 floor = (oracle.getQuote(tokenIn, middleToken, amountIn) * (BPS_DENOMINATOR - maxSlippageBps))
                / BPS_DENOMINATOR;
            if (minMiddleAmount < floor) {
                revert SlippageTooLow(minMiddleAmount, floor);
            }
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
        // Pin the destination token: the order's `tokenOut` must be part of the allowlisted route,
        // so a solver cannot deliver a worthless token to the recipient.
        if (!routeRegistry.isRouteAllowed(
                vault, address(this), routeToken, params.destChainId, params.destAddr, params.tokenOut
            )) {
            revert RouteNotAllowed(routeToken, params.destChainId, params.destAddr);
        }
    }
}
