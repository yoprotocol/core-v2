// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { IFxUSDBasePool } from "./../../interfaces/external/IFxUSDBasePool.sol";
import { ISavingFxUSD } from "./../../interfaces/external/ISavingFxUSD.sol";
import { IYoFxSaveAdapter } from "./../../interfaces/IYoFxSaveAdapter.sol";
import { IYoRegistry } from "./../../interfaces/IYoRegistry.sol";
import { YoAdapterBase } from "./../base/YoAdapterBase.sol";
import { YoFxSaveRedeemer } from "./YoFxSaveRedeemer.sol";

/// @title  YoFxSaveAdapter
/// @notice Immutable fxSAVE redemption adapter: instant redeem (sync, fee) and cooldown redeem
///         (async, fee-free) on behalf of a vault. Deposits are out of scope. See
///         `IYoFxSaveAdapter` for the approval / flow contract.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`; every payout
///             resolves to the vault.
///           - The cooldown path routes through a per-vault {YoFxSaveRedeemer} (CREATE2, salt =
///             vault) so locked positions never commingle across vaults.
///           - Each call leaks zero new fxSAVE / base / fxUSD / USDC balance to outside parties;
///             pre-existing dust is recoverable by registered YO vaults via `rescue` / `rescueETH`
///             (see {YoAdapterBase}).
contract YoFxSaveAdapter is YoAdapterBase, IYoFxSaveAdapter {
    using SafeERC20 for IERC20;

    /// @notice The fxSAVE vault this adapter redeems from.
    ISavingFxUSD public immutable fxSave;

    /// @notice fxSAVE's underlying `FxUSDBasePool`, where redemptions ultimately settle.
    IFxUSDBasePool public immutable base;

    /// @notice The yield-leg payout token (fxUSD on mainnet).
    IERC20 public immutable fxUsd;

    /// @notice The stable-leg payout token (USDC on mainnet).
    IERC20 public immutable usdc;

    /// @dev Cached `keccak256` of the per-vault redeemer init code, for CREATE2 address prediction.
    bytes32 private immutable _redeemerInitCodeHash;

    constructor(ISavingFxUSD _fxSave, IYoRegistry _yoRegistry) YoAdapterBase(_yoRegistry) {
        fxSave = _fxSave;
        IFxUSDBasePool _base = _fxSave.base();
        base = _base;
        fxUsd = IERC20(_base.yieldToken());
        usdc = IERC20(_base.stableToken());
        _redeemerInitCodeHash = keccak256(abi.encodePacked(type(YoFxSaveRedeemer).creationCode, abi.encode(_fxSave)));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   INSTANT REDEEM
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoFxSaveAdapter
    function instantRedeem(uint256 shares) external nonReentrant returns (uint256 fxUsdOut, uint256 usdcOut) {
        if (shares == 0) {
            revert InvalidAmount();
        }
        address vault = msg.sender;

        IERC20(address(fxSave)).safeTransferFrom(vault, address(this), shares);

        // Unwrap fxSAVE → base-pool shares held by the adapter, then settle those instantly with the
        // vault as receiver. Diff the balance to ignore any pre-existing base-share dust.
        uint256 baseBefore = base.balanceOf(address(this));
        fxSave.redeem(shares, address(this), address(this));
        uint256 baseGot = base.balanceOf(address(this)) - baseBefore;

        (fxUsdOut, usdcOut) = base.instantRedeem(vault, baseGot);

        _emitAction(address(fxSave), address(fxUsd), AdapterDirection.Withdraw, fxUsdOut);
        _emitAction(address(fxSave), address(usdc), AdapterDirection.Withdraw, usdcOut);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   REQUEST REDEEM
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoFxSaveAdapter
    function requestRedeem(uint256 shares) external nonReentrant returns (uint256 assets) {
        if (shares == 0) {
            revert InvalidAmount();
        }
        address vault = msg.sender;
        YoFxSaveRedeemer redeemer = _deployRedeemer(vault);

        // The redeemer must own the fxSAVE shares so its `requestRedeem` burns from itself, keeping
        // the locked position keyed to the vault's dedicated `msg.sender`.
        IERC20(address(fxSave)).safeTransferFrom(vault, address(redeemer), shares);
        assets = redeemer.requestRedeem(shares);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                       CLAIM
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoFxSaveAdapter
    function claim() external nonReentrant returns (uint256 fxUsdOut, uint256 usdcOut) {
        address vault = msg.sender;
        address redeemer = redeemerOf(vault);
        if (redeemer.code.length == 0) {
            revert NoPosition();
        }

        uint256 fxUsdBefore = fxUsd.balanceOf(vault);
        uint256 usdcBefore = usdc.balanceOf(vault);

        YoFxSaveRedeemer(redeemer).claim(vault);

        fxUsdOut = fxUsd.balanceOf(vault) - fxUsdBefore;
        usdcOut = usdc.balanceOf(vault) - usdcBefore;

        _emitAction(address(fxSave), address(fxUsd), AdapterDirection.Withdraw, fxUsdOut);
        _emitAction(address(fxSave), address(usdc), AdapterDirection.Withdraw, usdcOut);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      INTERNAL
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoFxSaveAdapter
    function redeemerOf(address vault) public view returns (address) {
        return Create2.computeAddress(_salt(vault), _redeemerInitCodeHash, address(this));
    }

    /// @dev Deploy the vault's redeemer if it does not yet exist; idempotent.
    function _deployRedeemer(address vault) private returns (YoFxSaveRedeemer redeemer) {
        address predicted = redeemerOf(vault);
        if (predicted.code.length == 0) {
            bytes memory initCode = abi.encodePacked(type(YoFxSaveRedeemer).creationCode, abi.encode(fxSave));
            predicted = Create2.deploy(0, _salt(vault), initCode);
        }
        redeemer = YoFxSaveRedeemer(predicted);
    }

    /// @dev Deterministic CREATE2 salt for a vault's redeemer.
    function _salt(address vault) private pure returns (bytes32) {
        return keccak256(abi.encode(vault));
    }
}
