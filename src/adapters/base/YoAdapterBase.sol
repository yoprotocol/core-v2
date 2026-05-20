// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IYoRegistry } from "../../interfaces/IYoRegistry.sol";

/// @title  YoAdapterBase
/// @notice Shared base for every YO adapter. Provides the `rescue` / `rescueETH` recovery surface
///         and the canonical `nonReentrant` guard.
///
///         The rescue methods are callable only by a currently-registered YO vault (per
///         `YoRegistry.isYoVault`) and always send recovered funds to `msg.sender` — there is no
///         caller-controlled destination. Combined with the immutable `YoRegistry` reference, this
///         means the only way to receive funds via rescue is to be allowlisted by the multisig
///         that owns the registry.
///
/// @dev    INVARIANTS:
///           - The adapter holds no admin keys and no upgrade path.
///           - Rescue is permissioned by *current* registry membership; a removed vault loses
///             rescue rights.
///           - Funds always flow to `msg.sender`; the rescue path cannot be redirected.
///           - Rescue shares the same reentrancy guard as the adapter's primary methods, so no
///             cross-method reentry is possible.
abstract contract YoAdapterBase is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Registry consulted to validate rescue callers. Immutable for the lifetime of the
    ///         adapter; if a new registry is ever needed, redeploy.
    IYoRegistry public immutable yoRegistry;

    error CallerNotYoVault(address caller);
    error ZeroRegistry();
    error EthTransferFailed();

    /// @notice Emitted on every successful `rescue(IERC20)`. `amount == 0` is permitted and emits.
    event Rescued(address indexed token, address indexed to, uint256 amount);
    /// @notice Emitted on every successful `rescueETH()`. `amount == 0` is permitted and emits.
    event RescuedETH(address indexed to, uint256 amount);

    /// @notice Direction of value flow relative to the calling vault.
    /// @dev    `Deposit` = vault → external protocol; `Withdraw` = external protocol → vault.
    ///         `YoSwapAdapter` does not emit `AdapterAction`; it has its own `SwapAction` event
    ///         that captures both legs of an exchange in a single log.
    enum AdapterDirection {
        Deposit,
        Withdraw
    }

    /// @notice Vault-level audit signal emitted by every adapter operation. Lets off-chain
    ///         monitoring reconstruct strategy actions without parsing each external protocol's logs.
    /// @param  vault     The calling YO vault (always `msg.sender` for adapter entrypoints).
    /// @param  target    The external protocol contract the adapter interacted with.
    /// @param  asset     The ERC-20 token whose movement defines this leg of the action.
    /// @param  direction Inflow or outflow relative to the vault.
    /// @param  amount    Quantity of `asset` in its native decimals.
    event AdapterAction(
        address indexed vault,
        address indexed target,
        address indexed asset,
        AdapterDirection direction,
        uint256 amount
    );

    constructor(IYoRegistry _yoRegistry) {
        if (address(_yoRegistry) == address(0)) {
            revert ZeroRegistry();
        }
        yoRegistry = _yoRegistry;
    }

    /// @dev Restricts the caller to a currently-registered YO vault. Applied to `rescue` /
    ///      `rescueETH`; child adapters' per-protocol methods are gated by their own allowlists
    ///      and do not use this modifier.
    modifier onlyYoVault() {
        if (!yoRegistry.isYoVault(msg.sender)) {
            revert CallerNotYoVault(msg.sender);
        }
        _;
    }

    /// @notice Sweep this adapter's full balance of `token` to the calling vault. Callable only by
    ///         a currently-registered YO vault.
    /// @return amount The token balance transferred.
    function rescue(IERC20 token) external nonReentrant onlyYoVault returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount != 0) {
            token.safeTransfer(msg.sender, amount);
        }
        emit Rescued(address(token), msg.sender, amount);
    }

    /// @dev Emit an `AdapterAction` log keyed on `msg.sender` (the calling vault). Used by every
    ///      adapter at the point a deposit / withdraw / swap leg completes.
    function _emitAction(address target, address asset, AdapterDirection direction, uint256 amount) internal {
        emit AdapterAction(msg.sender, target, asset, direction, amount);
    }

    /// @notice Sweep this adapter's full ETH balance to the calling vault. Callable only by a
    ///         currently-registered YO vault.
    /// @return amount The ETH amount transferred.
    function rescueETH() external nonReentrant onlyYoVault returns (uint256 amount) {
        amount = address(this).balance;
        if (amount != 0) {
            (bool ok,) = payable(msg.sender).call{ value: amount }("");
            if (!ok) {
                revert EthTransferFailed();
            }
        }
        emit RescuedETH(msg.sender, amount);
    }
}
