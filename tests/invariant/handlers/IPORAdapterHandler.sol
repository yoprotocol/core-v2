// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/src/Test.sol";

import { IIPORPlasmaVault } from "src/interfaces/external/IIPORPlasmaVault.sol";
import { YoIPORAdapter } from "src/adapters/ipor/YoIPORAdapter.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockIIPORPlasmaVault } from "../../mocks/MockIIPORPlasmaVault.sol";
import { MockIIPORWithdrawManager } from "../../mocks/MockIIPORWithdrawManager.sol";
import { Store } from "../stores/Store.sol";

contract IPORAdapterHandler is Test {
    YoIPORAdapter internal adapter;
    address internal vault;
    MockERC20 internal token;
    MockIIPORPlasmaVault internal plasmaVault;
    MockIIPORWithdrawManager internal withdrawManager;
    Store internal store;

    constructor(
        YoIPORAdapter _adapter,
        address _vault,
        MockERC20 _token,
        MockIIPORPlasmaVault _plasmaVault,
        MockIIPORWithdrawManager _withdrawManager,
        Store _store
    ) {
        adapter = _adapter;
        vault = _vault;
        token = _token;
        plasmaVault = _plasmaVault;
        withdrawManager = _withdrawManager;
        store = _store;
    }

    function deposit(uint256 assets) external {
        assets = bound(assets, 1, 100_000e6);
        if (token.balanceOf(vault) < assets) {
            token.mint(vault, assets);
        }
        vm.prank(vault);
        try adapter.deposit(IIPORPlasmaVault(address(plasmaVault)), assets) returns (uint256) {
            store.recordSupply(assets);
        } catch { }
    }

    function claim(uint256 shares) external {
        uint256 bal = plasmaVault.balanceOf(vault);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);

        // Real IPOR flow: vault first calls `requestShares` (outside the adapter), keeper later
        // releases funds, then the adapter calls `redeemFromRequest`. Replay that here so the
        // mock's mutating eligibility check passes deterministically.
        vm.prank(vault);
        withdrawManager.requestShares(shares);
        // Move past the request timestamp without leaving the window.
        vm.warp(block.timestamp + 1);
        withdrawManager.releaseFunds(block.timestamp, shares);

        vm.prank(vault);
        try adapter.claim(IIPORPlasmaVault(address(plasmaVault)), shares) returns (uint256 out) {
            store.recordWithdraw(out);
        } catch { }
    }
}
