// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IYoERC4626Adapter } from "../../interfaces/IYoERC4626Adapter.sol";
import { IYoERC4626VaultRegistry } from "../../interfaces/IYoERC4626VaultRegistry.sol";

/// @title  YoERC4626Adapter
/// @notice Immutable adapter for any ERC-4626 yield vault (MetaMorpho, Yearn V3, Pendle PT, etc.).
///         See `IYoERC4626Adapter` for the approval-flow contract.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`.
///           - `receiver` and `owner` to `IERC4626.deposit`/`withdraw`/`redeem` are always
///             `msg.sender`.
///           - Adapter holds zero balance and zero allowance to the yield vault at the end of
///             every call.
contract YoERC4626Adapter is ReentrancyGuard, IYoERC4626Adapter {
    using SafeERC20 for IERC20;

    IYoERC4626VaultRegistry public immutable registry;

    constructor(IYoERC4626VaultRegistry _registry) {
        registry = _registry;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      DEPOSIT
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoERC4626Adapter
    function deposit(
        IERC4626 yieldVault,
        uint256 assets
    )
        external
        nonReentrant
        returns (uint256 sharesReceived)
    {
        if (assets == 0) {
            revert InvalidAmount();
        }
        address vault = _authorize(yieldVault);

        IERC20 asset = IERC20(yieldVault.asset());
        uint256 sharesBefore = yieldVault.balanceOf(vault);

        asset.safeTransferFrom(vault, address(this), assets);
        asset.forceApprove(address(yieldVault), assets);

        sharesReceived = yieldVault.deposit(assets, vault);

        asset.forceApprove(address(yieldVault), 0);

        uint256 sharesAfter = yieldVault.balanceOf(vault);
        if (sharesAfter <= sharesBefore) {
            revert NoShareDelta();
        }

        uint256 leftoverBal = asset.balanceOf(address(this));
        if (leftoverBal != 0) {
            revert LeftoverBalance(address(asset), leftoverBal);
        }
        uint256 leftoverAllow = asset.allowance(address(this), address(yieldVault));
        if (leftoverAllow != 0) {
            revert LeftoverAllowance(address(asset), leftoverAllow);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      WITHDRAW
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoERC4626Adapter
    function withdraw(
        IERC4626 yieldVault,
        uint256 assets
    )
        external
        nonReentrant
        returns (uint256 sharesBurned)
    {
        if (assets == 0) {
            revert InvalidAmount();
        }
        address vault = _authorize(yieldVault);

        // Adapter is caller; yield vault verifies allowance(vault, adapter) on shares.
        sharesBurned = yieldVault.withdraw(assets, vault, vault);
    }

    /// @inheritdoc IYoERC4626Adapter
    function withdrawAll(
        IERC4626 yieldVault
    )
        external
        nonReentrant
        returns (uint256 assetsReceived)
    {
        address vault = _authorize(yieldVault);

        uint256 shares = yieldVault.balanceOf(vault);
        if (shares == 0) {
            revert NoPosition(yieldVault);
        }

        assetsReceived = yieldVault.redeem(shares, vault, vault);
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
