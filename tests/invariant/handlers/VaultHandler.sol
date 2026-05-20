// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/src/Test.sol";

import { IYoApprovalRegistry } from "src/interfaces/IYoApprovalRegistry.sol";
import { YoVault } from "src/YoVault.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { Store } from "../stores/Store.sol";

/// @notice Foundry invariant handler for the real `YoVault` proxy. Drives the user-facing flow
///         (deposit / mint / requestRedeem) and the operator-facing flow (fulfillRedeem,
///         cancelRedeem, pause/unpause, fee updates, approveToken). All entrypoints try/catch so
///         the handler itself never reverts — only the invariant assertions do.
contract VaultHandler is Test {
    YoVault internal yoVault;
    MockERC20 internal asset;
    IYoApprovalRegistry internal approvalRegistry;
    address internal operator;
    Store internal store;

    // Rotating set of depositors / receivers — enough actors to exercise multi-user pending state.
    address[3] internal actors;

    constructor(
        YoVault _yoVault,
        MockERC20 _asset,
        IYoApprovalRegistry _approvalRegistry,
        address _operator,
        address[3] memory _actors,
        Store _store
    ) {
        yoVault = _yoVault;
        asset = _asset;
        approvalRegistry = _approvalRegistry;
        operator = _operator;
        actors = _actors;
        store = _store;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                USER ENTRYPOINTS
    //////////////////////////////////////////////////////////////////////////*/

    function deposit(uint256 actorSeed, uint256 assets) external {
        address actor = _pickActor(actorSeed);
        assets = bound(assets, 1, 100_000e6);
        asset.mint(actor, assets);
        vm.prank(actor);
        asset.approve(address(yoVault), assets);

        uint256 supplyBefore = yoVault.totalSupply();
        uint256 feeRecipientBalBefore = _feeRecipientBalance();

        vm.prank(actor);
        try yoVault.deposit(assets, actor) returns (uint256 shares) {
            store.recordMint(shares);
            _accrueFees(feeRecipientBalBefore);
            require(yoVault.totalSupply() == supplyBefore + shares, "supply delta != minted");
        } catch { }
    }

    function mint(uint256 actorSeed, uint256 shares) external {
        address actor = _pickActor(actorSeed);
        shares = bound(shares, 1, 100_000e6);
        // Mint a generous buffer; the vault pulls exactly what `previewMint` reports.
        asset.mint(actor, 200_000e6);
        vm.prank(actor);
        asset.approve(address(yoVault), type(uint256).max);

        uint256 supplyBefore = yoVault.totalSupply();
        uint256 feeRecipientBalBefore = _feeRecipientBalance();

        vm.prank(actor);
        try yoVault.mint(shares, actor) {
            store.recordMint(shares);
            _accrueFees(feeRecipientBalBefore);
            require(yoVault.totalSupply() == supplyBefore + shares, "supply delta != minted");
        } catch { }
    }

    function requestRedeem(uint256 actorSeed, uint256 shares) external {
        address actor = _pickActor(actorSeed);
        uint256 bal = yoVault.balanceOf(actor);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);

        uint256 supplyBefore = yoVault.totalSupply();
        uint256 feeRecipientBalBefore = _feeRecipientBalance();

        vm.prank(actor);
        try yoVault.requestRedeem(shares, actor, actor) returns (uint256) {
            // The return value is `assetsWithFee` for the instant path and `REQUEST_ID` (0) for the
            // queued path — but these collide when the redeem price rounds assets down to zero, so
            // detect instant vs queued by checking the supply delta instead.
            uint256 supplyAfter = yoVault.totalSupply();
            if (supplyAfter < supplyBefore) {
                store.recordBurn(supplyBefore - supplyAfter);
                _accrueFees(feeRecipientBalBefore);
            } else {
                store.recordPendingRecipient(actor);
            }
        } catch { }
    }

    /*//////////////////////////////////////////////////////////////////////////
                              OPERATOR ENTRYPOINTS
    //////////////////////////////////////////////////////////////////////////*/

    function fulfillRedeem(uint256 actorSeed, uint256 sharesSeed, uint256 assetsSeed) external {
        address recipient = _pickActor(actorSeed);
        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(recipient);
        if (pendingShares == 0) return;
        uint256 shares = bound(sharesSeed, 1, pendingShares);
        uint256 assets = bound(assetsSeed, 1, pendingAssets);

        // Ensure the vault has enough asset balance to settle the requested gross.
        if (asset.balanceOf(address(yoVault)) < assets) {
            asset.mint(address(yoVault), assets - asset.balanceOf(address(yoVault)));
        }

        uint256 supplyBefore = yoVault.totalSupply();
        uint256 feeRecipientBalBefore = _feeRecipientBalance();

        vm.prank(operator);
        try yoVault.fulfillRedeem(recipient, shares, assets) {
            store.recordBurn(shares);
            _accrueFees(feeRecipientBalBefore);
            require(yoVault.totalSupply() == supplyBefore - shares, "supply delta != burnt");
        } catch { }
    }

    function cancelRedeem(uint256 actorSeed, uint256 sharesSeed, uint256 assetsSeed) external {
        address recipient = _pickActor(actorSeed);
        (uint256 pendingAssets, uint256 pendingShares) = yoVault.pendingRedeemRequest(recipient);
        if (pendingShares == 0) return;
        uint256 shares = bound(sharesSeed, 1, pendingShares);
        uint256 assets = bound(assetsSeed, 1, pendingAssets);

        vm.prank(operator);
        try yoVault.cancelRedeem(recipient, shares, assets) { } catch { }
    }

    function pause() external {
        if (yoVault.paused()) return;
        vm.prank(operator);
        try yoVault.pause() {
            store.recordPause(yoVault.totalSupply());
        } catch { }
    }

    function unpause() external {
        if (!yoVault.paused()) return;
        vm.prank(operator);
        try yoVault.unpause() {
            store.recordUnpause();
        } catch { }
    }

    function updateWithdrawFee(uint256 newFee) external {
        // MAX_FEE = 1e17. Stay strictly below.
        newFee = bound(newFee, 0, 1e17 - 1);
        vm.prank(operator);
        try yoVault.updateWithdrawFee(newFee) { } catch { }
    }

    function updateDepositFee(uint256 newFee) external {
        newFee = bound(newFee, 0, 1e17 - 1);
        vm.prank(operator);
        try yoVault.updateDepositFee(newFee) { } catch { }
    }

    function approveToken(uint256 spenderSeed, uint256 amount) external {
        // Cycle through a small set of spenders; some are allowlisted in the registry, some aren't.
        address spender = actors[spenderSeed % actors.length];
        amount = bound(amount, 0, 2_000_000e6);

        uint256 capBefore = approvalRegistry.maxApproval(address(yoVault), address(asset), spender);

        bytes memory data = abi.encodeWithSelector(YoVault.approveToken.selector, address(asset), spender, amount);

        vm.prank(operator);
        try yoVault.manage(address(yoVault), data, 0) {
            // Vault claims success → registry cap must have been >= amount (when amount > 0).
            if (amount > 0 && capBefore < amount) {
                store.flagApproveTokenViolation();
            }
        } catch { }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _feeRecipientBalance() internal view returns (uint256) {
        address r = yoVault.feeRecipient();
        if (r == address(0)) return 0;
        return asset.balanceOf(r);
    }

    function _accrueFees(uint256 feeRecipientBalBefore) internal {
        address r = yoVault.feeRecipient();
        if (r == address(0)) return;
        uint256 newBal = asset.balanceOf(r);
        if (newBal > feeRecipientBalBefore) {
            store.recordFeeAccrued(newBal - feeRecipientBalBefore);
        }
    }
}
