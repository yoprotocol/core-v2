// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { IAcrossSpokePool } from "../../interfaces/external/IAcrossSpokePool.sol";
import { IYoAcrossAdapter } from "../../interfaces/IYoAcrossAdapter.sol";
import { IYoBridgeRouteRegistry } from "../../interfaces/IYoBridgeRouteRegistry.sol";
import { IYoRegistry } from "../../interfaces/IYoRegistry.sol";
import { YoAdapterBase } from "../base/YoAdapterBase.sol";

/// @title  YoAcrossAdapter
/// @notice Immutable adapter for Across Protocol cross-chain deposits. See `IYoAcrossAdapter` for
///         the approval / route contract.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`; the origin-chain
///             `depositor` is forced to the vault so refunds return to it.
///           - Funds may only leave to a route allowlisted in `routeRegistry`.
///           - Each call leaks zero new balance / zero allowance to the SpokePool; pre-existing dust
///             is recoverable by registered YO vaults via `rescue` / `rescueETH` (see {YoAdapterBase}).
contract YoAcrossAdapter is YoAdapterBase, IYoAcrossAdapter {
    using SafeERC20 for IERC20;
    using Address for address;

    /// @dev Across integrator-ID tag appended to the deposit calldata for referral attribution: the
    ///      Across delimiter (`0x1dc0de`) followed by YO's 2-byte integrator id (`0x0088`). It trails
    ///      the ABI-encoded arguments, so the SpokePool decoder ignores it while Across's off-chain
    ///      indexer reads it for integrator attribution.
    bytes private constant _REFERRAL_TAG = hex"1dc0de0088";

    /// @notice The Across `SpokePool` this adapter deposits into.
    IAcrossSpokePool public immutable spokePool;

    /// @notice Allowlist of permitted `(vault, adapter, token, destinationChainId, recipient)` routes.
    IYoBridgeRouteRegistry public immutable routeRegistry;

    constructor(
        IAcrossSpokePool _spokePool,
        IYoBridgeRouteRegistry _routeRegistry,
        IYoRegistry _yoRegistry
    )
        YoAdapterBase(_yoRegistry)
    {
        spokePool = _spokePool;
        routeRegistry = _routeRegistry;
    }

    /// @inheritdoc IYoAcrossAdapter
    function deposit(DepositParams calldata params) external nonReentrant returns (uint256) {
        if (params.inputAmount == 0) {
            revert InvalidAmount();
        }
        if (!routeRegistry.isRouteAllowed(
                msg.sender, address(this), params.inputToken, params.destinationChainId, params.recipient
            )) {
            revert RouteNotAllowed(params.inputToken, params.destinationChainId, params.recipient);
        }

        IERC20(params.inputToken).safeTransferFrom(msg.sender, address(this), params.inputAmount);
        IERC20(params.inputToken).forceApprove(address(spokePool), params.inputAmount);

        _forwardDeposit(params);

        IERC20(params.inputToken).forceApprove(address(spokePool), 0);

        _emitAction(address(spokePool), params.inputToken, AdapterDirection.Bridge, params.inputAmount);
        return params.inputAmount;
    }

    /// @dev Forward the deposit to the SpokePool. Called internally (no `CALL`), so `msg.sender` is
    ///      still the vault — forced as `depositor` so origin-chain refunds return to it. The calldata
    ///      is built with `abi.encodeCall` (compile-time type-checked against the SpokePool ABI) and
    ///      dispatched with a low-level call so the referral tag can trail the encoded arguments.
    function _forwardDeposit(DepositParams calldata params) private {
        bytes memory data = abi.encodeCall(
            IAcrossSpokePool.deposit,
            (
                bytes32(uint256(uint160(msg.sender))),
                params.recipient,
                bytes32(uint256(uint160(params.inputToken))),
                params.outputToken,
                params.inputAmount,
                params.outputAmount,
                params.destinationChainId,
                params.exclusiveRelayer,
                params.quoteTimestamp,
                params.fillDeadline,
                params.exclusivityDeadline,
                params.message
            )
        );
        address(spokePool).functionCall(bytes.concat(data, _REFERRAL_TAG));
    }
}
