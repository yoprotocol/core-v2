// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IIPORPlasmaVault } from "../../interfaces/external/IIPORPlasmaVault.sol";
import { IYoERC4626VaultRegistry } from "../../interfaces/IYoERC4626VaultRegistry.sol";
import { IYoIPORAdapter } from "../../interfaces/IYoIPORAdapter.sol";
import { IYoRegistry } from "../../interfaces/IYoRegistry.sol";
import { YoAdapterBase } from "../base/YoAdapterBase.sol";

/// @title  YoIPORAdapter
/// @notice Immutable adapter for IPOR Fusion `PlasmaVault`s. See `IYoIPORAdapter` for the
///         approval-flow contract and the rationale for routing `requestShares` outside the
///         adapter.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`.
///           - `receiver` and `owner` to `IIPORPlasmaVault.deposit` / `redeemFromRequest` are
///             always `msg.sender`.
///           - Each call leaks zero new balance / zero allowance to the PlasmaVault; pre-existing
///             dust is recoverable by registered YO vaults via `rescue` / `rescueETH`
///             (see {YoAdapterBase}).
///           - Vault allowlist is shared with `YoERC4626Adapter` — same `YoERC4626VaultRegistry`.
contract YoIPORAdapter is YoAdapterBase, IYoIPORAdapter {
    using SafeERC20 for IERC20;

    IYoERC4626VaultRegistry public immutable registry;

    constructor(IYoERC4626VaultRegistry _registry, IYoRegistry _yoRegistry) YoAdapterBase(_yoRegistry) {
        registry = _registry;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      DEPOSIT
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoIPORAdapter
    function deposit(
        IIPORPlasmaVault plasmaVault,
        uint256 assets
    )
        external
        nonReentrant
        returns (uint256 sharesReceived)
    {
        if (assets == 0) {
            revert InvalidAmount();
        }
        address vault = _authorize(plasmaVault);

        IERC20 asset = IERC20(plasmaVault.asset());

        asset.safeTransferFrom(vault, address(this), assets);
        asset.forceApprove(address(plasmaVault), assets);

        sharesReceived = plasmaVault.deposit(assets, vault);

        asset.forceApprove(address(plasmaVault), 0);

        _emitAction(address(plasmaVault), address(asset), AdapterDirection.Deposit, assets);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                       CLAIM
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoIPORAdapter
    function claim(IIPORPlasmaVault plasmaVault, uint256 shares)
        external
        nonReentrant
        returns (uint256 assetsReceived)
    {
        if (shares == 0) {
            revert InvalidAmount();
        }
        address vault = _authorize(plasmaVault);
        assetsReceived = plasmaVault.redeemFromRequest(shares, vault, vault);

        _emitAction(address(plasmaVault), plasmaVault.asset(), AdapterDirection.Withdraw, assetsReceived);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     INTERNAL
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Resolve `msg.sender` as the vault and check the PlasmaVault is allowlisted for it.
    function _authorize(IIPORPlasmaVault plasmaVault) internal view returns (address vault) {
        vault = msg.sender;
        if (!registry.isAllowed(vault, address(plasmaVault))) {
            revert VaultNotAllowed(plasmaVault);
        }
    }
}
