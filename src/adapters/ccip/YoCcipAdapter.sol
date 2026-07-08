// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CcipClient } from "../../interfaces/external/CcipClient.sol";
import { ICcipRouterClient } from "../../interfaces/external/ICcipRouterClient.sol";
import { IYoBridgeRouteRegistry } from "../../interfaces/IYoBridgeRouteRegistry.sol";
import { IYoCcipAdapter } from "../../interfaces/IYoCcipAdapter.sol";
import { IYoRegistry } from "../../interfaces/IYoRegistry.sol";
import { YoAdapterBase } from "../base/YoAdapterBase.sol";

/// @title  YoCcipAdapter
/// @notice Immutable adapter for Chainlink CCIP token transfers. See `IYoCcipAdapter` for the
///         approval / route contract.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`.
///           - The CCIP message payload (`data`) is always empty — token transfers only, never an
///             arbitrary cross-chain call.
///           - Funds may only leave to a route allowlisted in `routeRegistry`.
///           - The CCIP fee is paid ONLY in the native gas asset, from `msg.value`; an ERC-20/LINK
///             fee is not supported, so the fee never touches the bridged token's allowance.
///           - Each call leaks zero new balance / zero allowance to the router; the adapter forwards
///             exactly the quoted `fee`, and any native overpayment is recoverable by registered YO
///             vaults (which are payable via {Compatible}) through `rescue` / `rescueETH` (see
///             {YoAdapterBase}).
contract YoCcipAdapter is YoAdapterBase, IYoCcipAdapter {
    using SafeERC20 for IERC20;

    /// @notice The CCIP `Router` this adapter dispatches through.
    ICcipRouterClient public immutable router;

    /// @notice Allowlist of permitted `(vault, adapter, token, destChainSelector, recipient)` routes.
    IYoBridgeRouteRegistry public immutable routeRegistry;

    constructor(
        ICcipRouterClient _router,
        IYoBridgeRouteRegistry _routeRegistry,
        IYoRegistry _yoRegistry
    )
        YoAdapterBase(_yoRegistry)
    {
        router = _router;
        routeRegistry = _routeRegistry;
    }

    /// @inheritdoc IYoCcipAdapter
    function send(
        uint64 destinationChainSelector,
        bytes32 recipient,
        address token,
        uint256 amount,
        uint256 maxFee,
        bytes calldata extraArgs
    )
        external
        payable
        nonReentrant
        returns (bytes32 messageId)
    {
        if (amount == 0) {
            revert InvalidAmount();
        }
        address vault = msg.sender;
        // CCIP delivers the same token it transfers, so no output token is pinned (`bytes32(0)`).
        if (!routeRegistry.isRouteAllowed(vault, address(this), token, destinationChainSelector, recipient, bytes32(0)))
        {
            revert RouteNotAllowed(token, destinationChainSelector, recipient);
        }
        // Delivery truncates `recipient` to an EVM address; reject dirty high bits so the route check
        // cannot pass for a recipient that differs from where funds actually land.
        if (uint256(recipient) >> 160 != 0) {
            revert RecipientNotEvmAddress(recipient);
        }

        CcipClient.EVM2AnyMessage memory message = _buildMessage(recipient, token, amount, extraArgs);

        uint256 fee = router.getFee(destinationChainSelector, message);
        if (fee > maxFee) {
            revert FeeExceedsMax(fee, maxFee);
        }
        // Native-only fee, forwarded from `msg.value`; overpayment stays recoverable via `rescueETH`.
        if (msg.value < fee) {
            revert IncorrectNativeFee(msg.value, fee);
        }

        IERC20(token).safeTransferFrom(vault, address(this), amount);
        IERC20(token).forceApprove(address(router), amount);

        messageId = router.ccipSend{ value: fee }(destinationChainSelector, message);

        IERC20(token).forceApprove(address(router), 0);

        _emitAction(address(router), token, AdapterDirection.Bridge, amount);
    }

    /// @dev Assemble the token-only CCIP message: empty payload, single token leg, EVM recipient,
    ///      native fee (`feeToken == address(0)`).
    function _buildMessage(
        bytes32 recipient,
        address token,
        uint256 amount,
        bytes calldata extraArgs
    )
        private
        pure
        returns (CcipClient.EVM2AnyMessage memory message)
    {
        CcipClient.EVMTokenAmount[] memory tokenAmounts = new CcipClient.EVMTokenAmount[](1);
        tokenAmounts[0] = CcipClient.EVMTokenAmount({ token: token, amount: amount });

        message = CcipClient.EVM2AnyMessage({
            receiver: abi.encode(address(uint160(uint256(recipient)))),
            data: "",
            tokenAmounts: tokenAmounts,
            feeToken: address(0),
            extraArgs: extraArgs
        });
    }
}
