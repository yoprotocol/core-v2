// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IStETH } from "../../interfaces/external/IStETH.sol";
import { IWETH9 } from "../../interfaces/external/IWETH9.sol";
import { IWithdrawalQueueERC721 } from "../../interfaces/external/IWithdrawalQueueERC721.sol";
import { IYoLidoAdapter } from "../../interfaces/IYoLidoAdapter.sol";
import { IYoRegistry } from "../../interfaces/IYoRegistry.sol";
import { YoAdapterBase } from "../base/YoAdapterBase.sol";

/// @title  YoLidoAdapter
/// @notice Immutable Lido adapter: stake WETH → stETH (sync), request unstake → NFT (async), claim
///         matured NFT → WETH (sync). See `IYoLidoAdapter` for the approval contract.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`.
///           - All Lido / queue calls use the vault as `owner` / `receiver` (or transitively, via
///             adapter custody followed by a forward to the vault).
///           - Each call leaks zero new ETH / WETH / stETH-shares / allowances; pre-existing dust
///             is recoverable by registered YO vaults via `rescue` / `rescueETH`
///             (see {YoAdapterBase}).
///           - `receive` accepts ETH only from WETH (on `withdraw`) and the withdrawal queue (on
///             `claimWithdrawal`); all other senders revert. Prevents stray-ETH custody.
contract YoLidoAdapter is YoAdapterBase, IYoLidoAdapter {
    using SafeERC20 for IERC20;

    IStETH public immutable stETH;
    IWithdrawalQueueERC721 public immutable withdrawalQueue;
    IWETH9 public immutable weth;
    address public immutable referral;

    constructor(
        IStETH _stETH,
        IWithdrawalQueueERC721 _queue,
        IWETH9 _weth,
        address _referral,
        IYoRegistry _yoRegistry
    )
        YoAdapterBase(_yoRegistry)
    {
        stETH = _stETH;
        withdrawalQueue = _queue;
        weth = _weth;
        referral = _referral;
    }

    /// @dev Accept ETH only from WETH and the withdrawal queue. Anything else is a bug or attack.
    receive() external payable {
        if (msg.sender != address(weth) && msg.sender != address(withdrawalQueue)) {
            revert UnexpectedETH(msg.sender);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                       STAKE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoLidoAdapter
    function stake(uint256 wethAmount) external nonReentrant returns (uint256 stETHReceived) {
        if (wethAmount == 0) {
            revert InvalidAmount();
        }
        address vault = msg.sender;

        IERC20 wethToken = IERC20(address(weth));
        uint256 stETHSharesBefore = stETH.sharesOf(address(this));

        wethToken.safeTransferFrom(vault, address(this), wethAmount);
        weth.withdraw(wethAmount);

        // Lido mints shares to msg.sender (the adapter). Return value is shares, not stETH tokens.
        stETH.submit{ value: wethAmount }(referral);

        // Forward the just-minted shares to the vault using `transferShares` — the standard
        // ERC-20 `transfer` path would lose 1-2 wei to share↔token rounding and leave dust. Any
        // pre-existing dust shares stay put (no economic impact, see audit notes).
        uint256 mintedShares = stETH.sharesOf(address(this)) - stETHSharesBefore;
        stETH.transferShares(vault, mintedShares);
        // `transferShares` is exact in shares; convert via the canonical pure view to get the token
        // amount the vault received. Cheaper and more rebase-robust than diffing balanceOf reads.
        stETHReceived = stETH.getPooledEthByShares(mintedShares);
        if (stETHReceived == 0) {
            revert NoShareDelta();
        }

        _emitAction(address(stETH), address(weth), AdapterDirection.Deposit, wethAmount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  REQUEST UNSTAKE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoLidoAdapter
    function requestUnstake(uint256 stETHAmount) external nonReentrant returns (uint256 requestId) {
        if (stETHAmount == 0) {
            revert InvalidAmount();
        }
        address vault = msg.sender;
        IERC20 stETHToken = IERC20(address(stETH));

        uint256 adapterBalBefore = stETHToken.balanceOf(address(this));
        uint256 sharesBefore = stETH.sharesOf(address(this));
        stETHToken.safeTransferFrom(vault, address(this), stETHAmount);

        // Use the actual pulled balance (handles Lido's 1-2 wei rebasing rounding).
        uint256 received = stETHToken.balanceOf(address(this)) - adapterBalBefore;
        if (received == 0) {
            revert NoTransfer();
        }

        stETHToken.forceApprove(address(withdrawalQueue), received);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = received;
        uint256[] memory ids = withdrawalQueue.requestWithdrawals(amounts, vault);
        requestId = ids[0];

        stETHToken.forceApprove(address(withdrawalQueue), 0);

        uint256 sharesAfter = stETH.sharesOf(address(this));
        if (sharesAfter > sharesBefore) {
            stETH.transferShares(vault, sharesAfter - sharesBefore);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    CLAIM UNSTAKE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoLidoAdapter
    function claimUnstake(uint256 requestId) external nonReentrant returns (uint256 wethReceived) {
        address vault = msg.sender;
        IERC20 wethToken = IERC20(address(weth));

        uint256 ethBalBefore = address(this).balance;

        // Pull NFT from the vault. Vault must have set approval-for-all on the adapter at onboarding.
        withdrawalQueue.transferFrom(vault, address(this), requestId);

        // Adapter is now the NFT owner; claimWithdrawal sends ETH to msg.sender (adapter).
        withdrawalQueue.claimWithdrawal(requestId);
        uint256 ethReceived = address(this).balance - ethBalBefore;
        if (ethReceived == 0) {
            revert NoTransfer();
        }

        weth.deposit{ value: ethReceived }();
        wethToken.safeTransfer(vault, ethReceived);
        wethReceived = ethReceived;

        _emitAction(address(withdrawalQueue), address(weth), AdapterDirection.Withdraw, ethReceived);
    }
}
