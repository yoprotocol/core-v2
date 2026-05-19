// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Id, IMorpho, MarketParams } from "../../interfaces/IMorpho.sol";
import { IYoMorphoAdapter } from "../../interfaces/IYoMorphoAdapter.sol";
import { IYoMorphoMarketRegistry } from "../../interfaces/IYoMorphoMarketRegistry.sol";
import { IYoRegistry } from "../../interfaces/IYoRegistry.sol";
import { YoAdapterBase } from "../base/YoAdapterBase.sol";

/// @title  YoMorphoAdapter
/// @notice Immutable Morpho Blue adapter for `supply`, `withdraw`, `withdrawAll`. Forces every call to
///         settle assets and shares to `msg.sender`, eliminating recipient-redirection attacks.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`.
///           - `onBehalf` and `receiver` arguments to Morpho are always `msg.sender`.
///           - Morpho `data` is always `""` so no callback is ever triggered.
///           - Each call leaks zero new balance / zero allowance to Morpho; pre-existing dust is
///             recoverable by registered YO vaults via `rescue` / `rescueETH` (see {YoAdapterBase}).
contract YoMorphoAdapter is YoAdapterBase, IYoMorphoAdapter {
    using SafeERC20 for IERC20;

    /// @notice Vault-level Morpho audit log. Replaces the generic `AdapterAction` for Morpho
    ///         because the Morpho Blue router is a singleton across all markets — the `marketId`
    ///         is the discriminator, not the target address.
    /// @param  vault     The calling YO vault (always `msg.sender`).
    /// @param  marketId  Morpho Blue market identifier.
    /// @param  direction `Deposit` for supply, `Withdraw` for withdraw / withdrawAll.
    /// @param  amount    Assets supplied or withdrawn.
    event MorphoMarketAction(address indexed vault, Id indexed marketId, AdapterDirection direction, uint256 amount);

    IMorpho public immutable morpho;
    IYoMorphoMarketRegistry public immutable registry;

    constructor(
        IMorpho _morpho,
        IYoMorphoMarketRegistry _registry,
        IYoRegistry _yoRegistry
    )
        YoAdapterBase(_yoRegistry)
    {
        morpho = _morpho;
        registry = _registry;
    }

    /// @inheritdoc IYoMorphoAdapter
    function supply(
        Id marketId,
        uint256 assets
    )
        external
        nonReentrant
        returns (uint256 assetsSupplied, uint256 sharesSupplied)
    {
        if (assets == 0) {
            revert InvalidAmount();
        }
        address vault = msg.sender;
        if (!registry.isAllowed(vault, marketId)) {
            revert MarketNotAllowed(marketId);
        }

        MarketParams memory p = morpho.idToMarketParams(marketId);
        if (p.loanToken == address(0)) {
            revert UnknownMarket(marketId);
        }

        IERC20 token = IERC20(p.loanToken);
        uint256 sharesBefore = morpho.position(marketId, vault).supplyShares;

        token.safeTransferFrom(vault, address(this), assets);
        token.forceApprove(address(morpho), assets);

        (assetsSupplied, sharesSupplied) = morpho.supply(p, assets, 0, vault, "");

        token.forceApprove(address(morpho), 0);

        uint256 sharesAfter = morpho.position(marketId, vault).supplyShares;
        if (sharesAfter <= sharesBefore) {
            revert NoShareDelta();
        }

        emit MorphoMarketAction(vault, marketId, AdapterDirection.Deposit, assetsSupplied);
    }

    /// @inheritdoc IYoMorphoAdapter
    function withdraw(
        Id marketId,
        uint256 assets
    )
        external
        nonReentrant
        returns (uint256 assetsWithdrawn, uint256 sharesBurned)
    {
        if (assets == 0) {
            revert InvalidAmount();
        }
        address vault = msg.sender;
        if (!registry.isAllowed(vault, marketId)) {
            revert MarketNotAllowed(marketId);
        }

        MarketParams memory p = morpho.idToMarketParams(marketId);
        if (p.loanToken == address(0)) {
            revert UnknownMarket(marketId);
        }

        (assetsWithdrawn, sharesBurned) = morpho.withdraw(p, assets, 0, vault, vault);

        emit MorphoMarketAction(vault, marketId, AdapterDirection.Withdraw, assetsWithdrawn);
    }

    /// @inheritdoc IYoMorphoAdapter
    function withdrawAll(Id marketId) external nonReentrant returns (uint256 assetsWithdrawn, uint256 sharesBurned) {
        address vault = msg.sender;
        if (!registry.isAllowed(vault, marketId)) {
            revert MarketNotAllowed(marketId);
        }

        MarketParams memory p = morpho.idToMarketParams(marketId);
        if (p.loanToken == address(0)) {
            revert UnknownMarket(marketId);
        }

        uint256 shares = morpho.position(marketId, vault).supplyShares;
        if (shares == 0) {
            revert NoPosition(marketId);
        }

        (assetsWithdrawn, sharesBurned) = morpho.withdraw(p, 0, shares, vault, vault);

        emit MorphoMarketAction(vault, marketId, AdapterDirection.Withdraw, assetsWithdrawn);
    }
}
