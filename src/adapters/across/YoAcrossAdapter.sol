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

    /// @dev ABI offset to the dynamic `message` tail: 12 head words × 32 bytes.
    uint256 private constant _MESSAGE_OFFSET = 12 * 32;

    /// @dev Forward the deposit to the SpokePool. The 12-argument `deposit` cannot be ABI-encoded as
    ///      a direct external call with the optimizer off (the `lite` profile): the encoder runs one
    ///      slot over the stack limit. To stay within it the calldata is assembled from shallow
    ///      pieces — two ≤6-field static chunks (the 11 leading args), the ABI offset word pointing
    ///      to the tail, and the trailing dynamic `message` encoded by hand as `[length][data]`
    ///      right-padded to a 32-byte boundary. (`abi.encode(message)` cannot be used for the tail: it
    ///      prepends its own offset word, which would corrupt the argument the head offset points at.)
    ///
    ///      Called internally (no `CALL`), so `msg.sender` is still the vault — forced as `depositor`
    ///      so origin-chain refunds return to it.
    function _forwardDeposit(DepositParams calldata params) private {
        bytes memory head = bytes.concat(
            abi.encode(
                bytes32(uint256(uint160(msg.sender))),
                params.recipient,
                bytes32(uint256(uint160(params.inputToken))),
                params.outputToken,
                params.inputAmount,
                params.outputAmount
            ),
            abi.encode(
                params.destinationChainId,
                params.exclusiveRelayer,
                params.quoteTimestamp,
                params.fillDeadline,
                params.exclusivityDeadline
            )
        );

        // Dynamic `bytes` tail: length word + raw data, right-padded to the next 32-byte boundary.
        bytes memory data = bytes.concat(
            IAcrossSpokePool.deposit.selector,
            head,
            bytes32(_MESSAGE_OFFSET),
            bytes32(params.message.length),
            params.message
        );
        uint256 remainder = params.message.length % 32;
        if (remainder != 0) {
            data = bytes.concat(data, new bytes(32 - remainder));
        }

        address(spokePool).functionCall(data);
    }
}
