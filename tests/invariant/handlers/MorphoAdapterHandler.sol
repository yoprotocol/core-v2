// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/src/Test.sol";

import { Id } from "src/interfaces/IMorpho.sol";
import { YoMorphoAdapter } from "src/adapters/morpho/YoMorphoAdapter.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { Store } from "../stores/Store.sol";

/// @notice Foundry invariant handler for the Morpho adapter. Handlers must NEVER revert during
///         invariant runs unless the adapter itself reverts.
contract MorphoAdapterHandler is Test {
    YoMorphoAdapter internal adapter;
    address internal vault;
    MockERC20 internal token;
    Id internal market;
    Store internal store;

    constructor(YoMorphoAdapter _adapter, address _vault, MockERC20 _token, Id _market, Store _store) {
        adapter = _adapter;
        vault = _vault;
        token = _token;
        market = _market;
        store = _store;
    }

    function supply(uint256 assets) external {
        assets = bound(assets, 1, 100_000e6);
        if (token.balanceOf(vault) < assets) {
            token.mint(vault, assets);
        }
        vm.prank(vault);
        try adapter.supply(market, assets) returns (uint256 supplied, uint256) {
            store.recordSupply(supplied);
        } catch { }
    }

    function withdraw(uint256 assets) external {
        assets = bound(assets, 1, 100_000e6);
        vm.prank(vault);
        try adapter.withdraw(market, assets) returns (uint256 out, uint256) {
            store.recordWithdraw(out);
        } catch { }
    }

    function withdrawAll() external {
        vm.prank(vault);
        try adapter.withdrawAll(market) returns (uint256 out, uint256) {
            store.recordWithdraw(out);
        } catch { }
    }
}
