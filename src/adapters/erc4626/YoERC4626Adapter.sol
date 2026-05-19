// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IYoERC4626Adapter } from "./../../interfaces/IYoERC4626Adapter.sol";
import { IYoERC4626VaultRegistry } from "./../../interfaces/IYoERC4626VaultRegistry.sol";
import { IYoRegistry } from "./../../interfaces/IYoRegistry.sol";
import { YoAdapterBase } from "./../base/YoAdapterBase.sol";

/// @title  YoERC4626Adapter
/// @notice Immutable adapter for any ERC-4626 yield vault (MetaMorpho, Yearn V3, Pendle PT, etc.).
///         See `IYoERC4626Adapter` for the approval-flow contract.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`.
///           - `receiver` and `owner` to `IERC4626.deposit`/`withdraw`/`redeem` are always
///             `msg.sender`.
///           - Each call leaks zero new balance / zero allowance to the yield vault; pre-existing
///             dust is recoverable by registered YO vaults via `rescue` / `rescueETH`
///             (see {YoAdapterBase}).
contract YoERC4626Adapter is YoAdapterBase, IYoERC4626Adapter {
    using SafeERC20 for IERC20;

    IYoERC4626VaultRegistry public immutable registry;

    constructor(IYoERC4626VaultRegistry _registry, IYoRegistry _yoRegistry) YoAdapterBase(_yoRegistry) {
        registry = _registry;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      DEPOSIT
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoERC4626Adapter
    function deposit(IERC4626 yieldVault, uint256 assets) external nonReentrant returns (uint256 sharesReceived) {
        if (assets == 0) {
            revert InvalidAmount();
        }
        address vault = _authorize(yieldVault);

        IERC20 asset = IERC20(yieldVault.asset());

        asset.safeTransferFrom(vault, address(this), assets);
        asset.forceApprove(address(yieldVault), assets);

        sharesReceived = yieldVault.deposit(assets, vault);

        asset.forceApprove(address(yieldVault), 0);

        _emitAction(address(yieldVault), address(asset), AdapterDirection.Deposit, assets);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      WITHDRAW
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoERC4626Adapter
    function withdraw(IERC4626 yieldVault, uint256 assets) external nonReentrant returns (uint256 sharesBurned) {
        if (assets == 0) {
            revert InvalidAmount();
        }
        address vault = _authorize(yieldVault);
        sharesBurned = yieldVault.withdraw(assets, vault, vault);

        _emitAction(address(yieldVault), yieldVault.asset(), AdapterDirection.Withdraw, assets);
    }

    /// @inheritdoc IYoERC4626Adapter
    function withdrawAll(IERC4626 yieldVault) external nonReentrant returns (uint256 assetsReceived) {
        address vault = _authorize(yieldVault);

        uint256 shares = yieldVault.balanceOf(vault);
        if (shares == 0) {
            revert NoPosition(yieldVault);
        }

        assetsReceived = yieldVault.redeem(shares, vault, vault);

        _emitAction(address(yieldVault), yieldVault.asset(), AdapterDirection.Withdraw, assetsReceived);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     INTERNAL
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Resolve `msg.sender` as the vault and check the yield vault is allowlisted for it.
    function _authorize(IERC4626 yieldVault) internal view returns (address vault) {
        vault = msg.sender;
        if (!registry.isAllowed(vault, address(yieldVault))) {
            revert VaultNotAllowed(yieldVault);
        }
    }
}
