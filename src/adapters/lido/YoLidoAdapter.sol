// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IStETH } from "../../interfaces/external/IStETH.sol";
import { IWETH9 } from "../../interfaces/external/IWETH9.sol";
import { IWithdrawalQueueERC721 } from "../../interfaces/external/IWithdrawalQueueERC721.sol";
import { IYoLidoAdapter } from "../../interfaces/IYoLidoAdapter.sol";

/// @title  YoLidoAdapter
/// @notice Immutable Lido adapter: stake WETH → stETH (sync), request unstake → NFT (async), claim
///         matured NFT → WETH (sync). See `IYoLidoAdapter` for the approval contract.
/// @dev    INVARIANTS:
///           - `msg.sender` is the vault when invoked via `YoVault.manage(...)`.
///           - All Lido / queue calls use the vault as `owner` / `receiver` (or transitively, via
///             adapter custody followed by a forward to the vault).
///           - Adapter ends every call with zero ETH, zero WETH, zero stETH-shares, zero allowances.
///           - `receive` accepts ETH only from WETH (on `withdraw`) and the withdrawal queue (on
///             `claimWithdrawal`); all other senders revert. Prevents stray-ETH custody.
contract YoLidoAdapter is ReentrancyGuard, IYoLidoAdapter {
    using SafeERC20 for IERC20;

    IStETH public immutable stETH;
    IWithdrawalQueueERC721 public immutable withdrawalQueue;
    IWETH9 public immutable weth;
    address public immutable referral;

    constructor(IStETH _stETH, IWithdrawalQueueERC721 _queue, IWETH9 _weth, address _referral) {
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
        wethToken.safeTransferFrom(vault, address(this), wethAmount);
        weth.withdraw(wethAmount);

        // Lido mints shares to msg.sender (the adapter). Return value is shares, not stETH tokens.
        stETH.submit{ value: wethAmount }(referral);

        // Forward the adapter's full share balance to the vault using transferShares — the standard
        // ERC-20 `transfer` path would lose 1-2 wei to share↔token rounding and leave dust.
        uint256 shares = stETH.sharesOf(address(this));
        stETH.transferShares(vault, shares);
        // `transferShares` is exact in shares; convert via the canonical pure view to get the token
        // amount the vault received. Cheaper and more rebase-robust than diffing balanceOf reads.
        stETHReceived = stETH.getPooledEthByShares(shares);
        if (stETHReceived == 0) {
            revert NoShareDelta();
        }

        if (address(this).balance != 0) {
            revert LeftoverEth(address(this).balance);
        }
        uint256 leftoverWeth = wethToken.balanceOf(address(this));
        if (leftoverWeth != 0) {
            revert LeftoverBalance(address(weth), leftoverWeth);
        }
        uint256 leftoverShares = stETH.sharesOf(address(this));
        if (leftoverShares != 0) {
            revert LeftoverShares(leftoverShares);
        }
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
        uint256 leftoverShares = stETH.sharesOf(address(this));
        if (leftoverShares != 0) {
            revert LeftoverShares(leftoverShares);
        }
        uint256 leftoverAllow = stETHToken.allowance(address(this), address(withdrawalQueue));
        if (leftoverAllow != 0) {
            revert LeftoverAllowance(address(stETH), leftoverAllow);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    CLAIM UNSTAKE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYoLidoAdapter
    function claimUnstake(uint256 requestId) external nonReentrant returns (uint256 wethReceived) {
        address vault = msg.sender;

        // Pull NFT from the vault. Vault must have set approval-for-all on the adapter at onboarding.
        withdrawalQueue.transferFrom(vault, address(this), requestId);

        // Adapter is now the NFT owner; claimWithdrawal sends ETH to msg.sender (adapter).
        uint256 ethBefore = address(this).balance;
        withdrawalQueue.claimWithdrawal(requestId);
        uint256 ethReceived = address(this).balance - ethBefore;
        if (ethReceived == 0) {
            revert NoTransfer();
        }

        weth.deposit{ value: ethReceived }();
        IERC20(address(weth)).safeTransfer(vault, ethReceived);
        wethReceived = ethReceived;

        if (address(this).balance != 0) {
            revert LeftoverEth(address(this).balance);
        }
        uint256 leftoverWeth = IERC20(address(weth)).balanceOf(address(this));
        if (leftoverWeth != 0) {
            revert LeftoverBalance(address(weth), leftoverWeth);
        }
    }
}
