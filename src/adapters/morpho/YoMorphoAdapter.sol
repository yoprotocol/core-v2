// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { Id, IMorpho, MarketParams } from "../../interfaces/IMorpho.sol";
import { IYoMorphoAdapter } from "../../interfaces/IYoMorphoAdapter.sol";
import { IYoMorphoMarketRegistry } from "../../interfaces/IYoMorphoMarketRegistry.sol";

/// @title  YoMorphoAdapter
/// @notice Immutable Morpho Blue adapter for `supply`, `withdraw`, `withdrawAll`. Forces every call to
///         settle assets and shares to `msg.sender`, eliminating recipient-redirection attacks.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`.
///           - `onBehalf` and `receiver` arguments to Morpho are always `msg.sender`.
///           - Morpho `data` is always `""` so no callback is ever triggered.
///           - Adapter holds zero balance and zero allowance to Morpho at the end of every call.
contract YoMorphoAdapter is ReentrancyGuard, IYoMorphoAdapter {
    using SafeERC20 for IERC20;

    IMorpho public immutable morpho;
    IYoMorphoMarketRegistry public immutable registry;

    constructor(IMorpho _morpho, IYoMorphoMarketRegistry _registry) {
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

        uint256 leftoverBal = token.balanceOf(address(this));
        if (leftoverBal != 0) {
            revert LeftoverBalance(p.loanToken, leftoverBal);
        }

        uint256 leftoverAllow = token.allowance(address(this), address(morpho));
        if (leftoverAllow != 0) {
            revert LeftoverAllowance(p.loanToken, leftoverAllow);
        }
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
    }
}
