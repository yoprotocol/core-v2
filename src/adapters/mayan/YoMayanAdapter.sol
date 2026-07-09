// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
///             (`referrerAddr`/`referrerBps` forced to zero), carries no `customPayload` (empty), pins
///             the plain-transfer `payloadType` and the `ENGLISH` `auctionMode` (a `BYPASS` auction
///             would let a colluding solver fill uncontested), and its `(destChainId, destAddr,
///             tokenOut)` is an allowlisted route (the destination token is part of the route key), and
///             its `cancelFee + refundFee` is capped at `maxOrderFeeBps` of the bridged amount — so
///             neither the output, its token, a refund/cancel skim, nor a referral fee can be
///             redirected off the vault, and no destination-side payload can be attached.
///           - This adapter bridges an asset to ITSELF on another chain (cbBTC→cbBTC, WETH→WETH,
///             USDC→USDC, ...), so on BOTH paths the destination `minAmountOut` is floored against the
///             vault's normalized input less `maxBridgeSlippageBps` — closing the operator+solver
///             dust-fill skim (mirrors Across's `outputAmount` floor). The transient swap-path
///             `middleToken` is irrelevant to this floor.
///           - `swapAndForwardERC20`'s source swap is additionally oracle-floored via
///             `YoSwapPairRegistry` + `YoSwapOracle` + `maxSwapSlippageBps`, so the operator cannot
///             drain the vault through a fake or underpriced middle token.
///           - Each call leaks zero new balance / zero allowance to the Forwarder; pre-existing dust
///             is recoverable by registered YO vaults via `rescue` / `rescueETH` (see {YoAdapterBase}).
contract YoMayanAdapter is YoAdapterBase, IYoMayanAdapter {
    using SafeERC20 for IERC20;

    /// @dev Swift's plain-transfer payload variant. Swift only treats `payloadType == 2` as a
    ///      payload-carrying order (it commits `keccak256(customPayload)` into the order hash and
    ///      changes destination fulfillment); every other value is a plain transfer. The SDK emits
    ///      `1` for plain transfers, so the adapter pins exactly `1` — the strictest plain variant.
    uint8 private constant _PLAIN_TRANSFER_PAYLOAD_TYPE = 1;

    /// @dev Swift's `AuctionMode` (`{ NONE: 0, BYPASS: 1, ENGLISH: 2 }`). `ENGLISH` is the competitive
    ///      on-chain auction the SDK emits for every real order; `BYPASS` would skip price discovery
    ///      and let a colluding solver fill uncontested. The adapter pins `ENGLISH` so the auction — the
    ///      market check on the fill price behind `minAmountOut` — cannot be turned off.
    uint8 private constant _ENGLISH_AUCTION_MODE = 2;

    /// @notice Immutable construction config. A struct keeps the constructor within the ≤5-positional
    ///         convention while carrying both the bridge wiring and the swap-floor wiring.
    /// @param forwarder      Mayan Forwarder the adapter forwards through.
    /// @param swiftProtocol  The single Mayan protocol (Swift) the adapter targets.
    /// @param routeRegistry  Destination allowlist `(vault, adapter, tokenIn, destChainId, destAddr)`.
    /// @param oracle         Price oracle flooring the source-swap leg.
    /// @param pairRegistry   Per-vault swap-pair allowlist for the source-swap leg.
    /// @param maxSwapSlippageBps   Max slippage (bps) on the `ORACLE_CHECKED` source swap leg.
    /// @param maxBridgeSlippageBps Max slippage (bps) on the `minAmountOut` delivery floor for BOTH
    ///                             paths — a plain bridge on `forwardERC20`, the full source-swap +
    ///                             bridge round trip on `swapAndForwardERC20`.
    /// @param maxOrderFeeBps       Max combined `cancelFee + refundFee` (bps of the normalized bridged
    ///                             amount) tolerated on a Swift order.
    /// @param yoRegistry           YO registry consulted for `rescue` auth (see {YoAdapterBase}).
    struct InitParams {
        IMayanForwarder forwarder;
        address swiftProtocol;
        IYoBridgeRouteRegistry routeRegistry;
        IYoSwapOracle oracle;
        IYoSwapPairRegistry pairRegistry;
        uint256 maxSwapSlippageBps;
        uint256 maxBridgeSlippageBps;
        uint256 maxOrderFeeBps;
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

    /// @notice Max slippage (bps) on the `ORACLE_CHECKED` source swap leg.
    uint256 public immutable maxSwapSlippageBps;

    /// @notice Max slippage (bps) on the `minAmountOut` delivery floor (both paths): a plain bridge on
    ///         the direct path, the source-swap + bridge round trip on the swap path.
    uint256 public immutable maxBridgeSlippageBps;

    /// @notice Max combined `cancelFee + refundFee` (bps of the normalized bridged amount) per order.
    uint256 public immutable maxOrderFeeBps;

    constructor(InitParams memory p) YoAdapterBase(p.yoRegistry) {
        forwarder = p.forwarder;
        swiftProtocol = p.swiftProtocol;
        routeRegistry = p.routeRegistry;
        oracle = p.oracle;
        pairRegistry = p.pairRegistry;
        maxSwapSlippageBps = p.maxSwapSlippageBps;
        maxBridgeSlippageBps = p.maxBridgeSlippageBps;
        maxOrderFeeBps = p.maxOrderFeeBps;
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
        _checkOrderFees(params, tokenIn, amountIn);
        // Direct bridge: `tokenIn` is the vault's asset and equals the order's `tokenOut` asset.
        _checkMinAmountOut(params, tokenIn, amountIn, maxBridgeSlippageBps);

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
        // Fee cap is keyed on the locked/refundable token — the bridged middle token.
        _checkOrderFees(order, params.middleToken, params.minMiddleAmount);
        // Delivery floor is keyed on the vault's OWN input (`tokenIn`), which equals the order's
        // `tokenOut` asset (same-asset bridge policy); the middle token is a transient. The round trip
        // (source swap + bridge) is wider than a plain bridge, so use `maxBridgeSlippageBps`.
        _checkMinAmountOut(order, params.tokenIn, params.amountIn, maxBridgeSlippageBps);

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
    ///      fail-closed. Returns the order's declared input token, amount, and params. Pins the order
    ///      shape: the trailing `customPayload` must be empty and `payloadType` must be the plain
    ///      transfer (no destination-side payload/hook), and `auctionMode` must be `ENGLISH` (no
    ///      bypassed auction).
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
        // Pin the plain-transfer variant. Even an empty `customPayload` under `payloadType == 2`
        // hashes to a non-zero `keccak256("")` in the order, switching Swift to its payload-delivery
        // path on the destination — which can strand/complicate a fill to a plain EOA recipient.
        if (params.payloadType != _PLAIN_TRANSFER_PAYLOAD_TYPE) {
            revert InvalidPayloadType(params.payloadType);
        }
        if (customPayload.length != 0) {
            revert CustomPayloadNotAllowed(customPayload.length);
        }
        // Pin the competitive English auction. A `BYPASS` auction skips price discovery, letting a
        // colluding solver fill uncontested — the market check standing behind `minAmountOut`.
        if (params.auctionMode != _ENGLISH_AUCTION_MODE) {
            revert InvalidAuctionMode(params.auctionMode);
        }
    }

    /// @dev Floor the source-swap leg exactly as `YoSwapAdapter` does: the `(tokenIn, middleToken)`
    ///      pair must be allowlisted, and when `ORACLE_CHECKED` the operator's `minMiddleAmount` must
    ///      clear the oracle quote less `maxSwapSlippageBps`. This pins both the middle-token identity
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
            uint256 floor =
                _applyBps(oracle.getQuote(tokenIn, middleToken, amountIn), BPS_DENOMINATOR - maxSwapSlippageBps);
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

    /// @dev Cap the order's `cancelFee + refundFee`. On the refund/cancel path Swift pays these out of
    ///      the vault's refund to whoever triggers it, so an unbounded value is an operator skim
    ///      channel (like the referrer fee). Bounded to `maxOrderFeeBps` of the normalized bridged
    ///      amount — the locked token's amount normalized to Swift's 8-decimal convention. Valid on
    ///      both paths: the fees are denominated in the locked token (`tokenIn` for the direct path,
    ///      `middleToken` for the swap path), which is exactly `lockedToken`. Legitimate
    ///      gas-compensation fees sit far below this; a near-`amountIn` skim is rejected.
    function _checkOrderFees(
        IMayanSwift.OrderParams memory params,
        address lockedToken,
        uint256 lockedAmount
    )
        private
        view
    {
        uint256 normalized = _normalizeAmount(lockedAmount, IERC20Metadata(lockedToken).decimals());
        uint256 cap = _applyBps(normalized, maxOrderFeeBps);
        uint256 fees = uint256(params.cancelFee) + uint256(params.refundFee);
        if (fees > cap) {
            revert OrderFeeTooHigh(fees, cap);
        }
    }

    /// @dev Floor the delivered `minAmountOut` against the vault's input, exactly as `YoAcrossAdapter`
    ///      floors `outputAmount`: `minAmountOut >= amount * (1 - slippageBps)`. This adapter bridges an
    ///      asset to ITSELF on another chain (cbBTC→cbBTC, WETH→WETH, USDC→USDC, ...), so `token`'s
    ///      value equals the order's `tokenOut` value 1:1 minus the spread; without this floor an
    ///      operator could set `minAmountOut ≈ 0` and a colluding solver fill for dust. Both amounts
    ///      are Swift-normalized (8-dp cap); the check assumes the bridged asset has the same decimals
    ///      on both chains — the assertion the multisig makes when allowlisting the route (true for
    ///      USDC 6/6, WETH 18/18, cbBTC 8/8; do NOT allowlist an asset whose decimals differ per chain,
    ///      e.g. USDT 6/18).
    /// @param token       The vault's outgoing asset: `tokenIn` on both paths (== the order's `tokenOut`
    ///                    asset, by the same-asset route policy). NOT the transient swap-path middle
    ///                    token.
    /// @param slippageBps `maxBridgeSlippageBps` on both paths (a plain bridge on the direct path, the
    ///                    source-swap + bridge round trip on the swap path).
    function _checkMinAmountOut(
        IMayanSwift.OrderParams memory params,
        address token,
        uint256 amount,
        uint256 slippageBps
    )
        private
        view
    {
        uint256 normalized = _normalizeAmount(amount, IERC20Metadata(token).decimals());
        uint256 floor = _applyBps(normalized, BPS_DENOMINATOR - slippageBps);
        if (uint256(params.minAmountOut) < floor) {
            revert MinAmountOutTooLow(params.minAmountOut, floor);
        }
    }

    /// @dev Normalize `amount` (in `decimals`) to Swift's normalized amount, matching Wormhole's
    ///      `normalizeAmount`: truncate the low digits for tokens with more than 8 decimals, leave
    ///      tokens with 8 or fewer decimals unchanged (Swift does NOT scale sub-8-decimal tokens up).
    function _normalizeAmount(uint256 amount, uint8 decimals) private pure returns (uint256) {
        return decimals > 8 ? amount / (10 ** (decimals - 8)) : amount;
    }
}
