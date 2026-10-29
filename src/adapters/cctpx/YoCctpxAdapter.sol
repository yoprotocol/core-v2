// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ICrossChainTokenService } from "../../interfaces/external/ICrossChainTokenService.sol";
import { IYoBridgeRouteRegistry } from "../../interfaces/IYoBridgeRouteRegistry.sol";
import { IYoCctpxAdapter } from "../../interfaces/IYoCctpxAdapter.sol";
import { IYoRegistry } from "../../interfaces/IYoRegistry.sol";
import { YoAdapterBase } from "../base/YoAdapterBase.sol";

/// @title  YoCctpxAdapter
/// @notice Immutable adapter for Circle "CCTP for non-USDC" (CCTPx) burn-and-mint transfers of one
///         pinned token (e.g. EURC). See `IYoCctpxAdapter` for the approval / route / fee contract.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`.
///           - The token and its CCTPx `tokenId` are pinned at construction; nothing else can be bridged.
///           - Funds may only leave to a route allowlisted in `routeRegistry`.
///           - Delivery goes to the raw 20-byte allowlisted `recipient` only, is relayable by anyone
///             (`destinationCaller == 0`), and runs no destination hook, so the adapter adds no strand
///             vector. Delivery still depends on Circle-side state (see `IYoCctpxAdapter`).
///           - Fee refunds are attributed to the vault, never to an operator-chosen address.
///           - The native fee is paid ONLY from `msg.value`, capped at `maxNativeFee`, and the
///             service must forward all of it as the fee: it neither keeps an excess nor tops up a
///             shortfall from its own balance.
///           - Each call leaks zero new balance / zero allowance to the `TokenManager`; pre-existing
///             dust is recoverable by registered YO vaults via `rescue` / `rescueETH` (see
///             {YoAdapterBase}).
contract YoCctpxAdapter is YoAdapterBase, IYoCctpxAdapter {
    using SafeERC20 for IERC20;

    /// @notice `minFinalityThreshold` of a fast transfer (needs a `PRE_FINALITY` quote item).
    uint32 public constant FINALITY_FAST = 1000;

    /// @notice `minFinalityThreshold` of a standard transfer (attested at finality).
    uint32 public constant FINALITY_STANDARD = 2000;

    /// @notice The CCTPx `CrossChainTokenService` this adapter transfers through.
    ICrossChainTokenService public immutable service;

    /// @notice The token transferred on this chain. Pinned at construction.
    IERC20 public immutable token;

    /// @notice The CCTPx cross-chain id of `token`. Pinned at construction.
    bytes32 public immutable tokenId;

    /// @notice Allowlist of permitted `(vault, adapter, token, destinationDomain, recipient)` routes.
    IYoBridgeRouteRegistry public immutable routeRegistry;

    /// @notice Max native fee (`msg.value`) tolerated per transfer, in wei.
    uint256 public immutable maxNativeFee;

    constructor(
        ICrossChainTokenService _service,
        IERC20 _token,
        bytes32 _tokenId,
        IYoBridgeRouteRegistry _routeRegistry,
        uint256 _maxNativeFee,
        IYoRegistry _yoRegistry
    )
        YoAdapterBase(_yoRegistry)
    {
        // Fail the deployment on a token / tokenId mismatch: the TokenManager would pull a different
        // token than the one the vault approved, so every transfer would revert.
        address registered = _service.resolveTokenAddress(_tokenId);
        if (registered != address(_token)) {
            revert TokenMismatch(address(_token), registered);
        }
        service = _service;
        token = _token;
        tokenId = _tokenId;
        routeRegistry = _routeRegistry;
        maxNativeFee = _maxNativeFee;
    }

    /// @inheritdoc IYoCctpxAdapter
    function crossChainTransfer(
        uint256 amount,
        uint32 destinationDomain,
        address recipient,
        uint32 minFinalityThreshold,
        bytes calldata signedQuote
    )
        external
        payable
        nonReentrant
        returns (uint256)
    {
        if (amount == 0) {
            revert InvalidAmount();
        }
        // CCTPx accepts a zero recipient on the source but reverts its delivery, which would strand
        // the burned tokens. Reject it even if a zero route were ever allowlisted.
        if (recipient == address(0)) {
            revert InvalidRecipient();
        }
        // Only the two documented tiers: any other value either pays the fast fee for a standard
        // attestation or depends on undocumented attester behaviour.
        if (minFinalityThreshold != FINALITY_FAST && minFinalityThreshold != FINALITY_STANDARD) {
            revert InvalidFinalityThreshold(minFinalityThreshold);
        }
        if (msg.value > maxNativeFee) {
            revert NativeFeeTooHigh(msg.value, maxNativeFee);
        }
        address vault = msg.sender;
        // CCTPx mints the same token on the destination, so no output token is pinned (`bytes32(0)`).
        if (!routeRegistry.isRouteAllowed(
                vault,
                address(this),
                address(token),
                destinationDomain,
                bytes32(uint256(uint160(recipient))),
                bytes32(0)
            )) {
            revert RouteNotAllowed(destinationDomain, recipient);
        }

        token.safeTransferFrom(vault, address(this), amount);
        // The per-token TokenManager pulls the tokens, so it (not the service) is the spender.
        address tokenManager = service.resolveTokenManager(tokenId);
        token.forceApprove(tokenManager, amount);

        _transfer(amount, destinationDomain, recipient, minFinalityThreshold, signedQuote);

        token.forceApprove(tokenManager, 0);

        _emitAction(address(service), address(token), AdapterDirection.Bridge, amount);
        return amount;
    }

    /// @dev Dispatch to the service with the delivery parameters fixed here rather than supplied by the
    ///      operator: the raw 20-byte recipient (CCTPx reverts delivery on a 32-byte encoding), any
    ///      relayer (`bytes32(0)`, no strand vector), no destination hook, and fee refunds attributed to
    ///      the vault.
    ///
    ///      The service pays the signed quote's total fee out of its OWN balance: it keeps any excess
    ///      `msg.value` and silently covers a shortfall from ETH earlier callers left behind. Requiring
    ///      its balance to be unchanged proves it spent exactly `msg.value` and none of its own ETH —
    ///      measured, not mirrored from Circle's quote decoding. That the spent ETH is the quoted fee
    ///      (and not, say, an excess the fee manager keeps) is Circle-trusted; `maxNativeFee` bounds it.
    function _transfer(
        uint256 amount,
        uint32 destinationDomain,
        address recipient,
        uint32 minFinalityThreshold,
        bytes calldata signedQuote
    )
        private
    {
        uint256 serviceBalance = address(service).balance;

        service.crossChainTransfer{ value: msg.value }(
            tokenId,
            amount,
            destinationDomain,
            abi.encodePacked(recipient),
            bytes32(0),
            minFinalityThreshold,
            ICrossChainTokenService.QuoteClaim({ signedQuote: signedQuote, refundAddress: payable(msg.sender) }),
            false,
            ""
        );

        uint256 serviceBalanceAfter = address(service).balance;
        if (serviceBalanceAfter != serviceBalance) {
            // The fee actually charged: `serviceBalance + msg.value - serviceBalanceAfter`. This only
            // underflows if the service gained ETH from elsewhere during the call, which still reverts.
            revert IncorrectNativeFee(msg.value, serviceBalance + msg.value - serviceBalanceAfter);
        }
    }
}
