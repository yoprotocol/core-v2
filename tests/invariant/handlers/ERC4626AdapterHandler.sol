// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/src/Test.sol";

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { YoERC4626Adapter } from "src/adapters/erc4626/YoERC4626Adapter.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { Store } from "../stores/Store.sol";

contract ERC4626AdapterHandler is Test {
    YoERC4626Adapter internal adapter;
    address internal vault;
    MockERC20 internal token;
    IERC4626 internal yieldVault;
    Store internal store;

    constructor(YoERC4626Adapter _adapter, address _vault, MockERC20 _token, IERC4626 _yieldVault, Store _store) {
        adapter = _adapter;
        vault = _vault;
        token = _token;
        yieldVault = _yieldVault;
        store = _store;
    }

    function deposit(uint256 assets) external {
        assets = bound(assets, 1, 100_000e6);
        if (token.balanceOf(vault) < assets) {
            token.mint(vault, assets);
        }
        vm.prank(vault);
        try adapter.deposit(yieldVault, assets) returns (uint256) {
            store.recordSupply(assets);
        } catch { }
    }

    function withdraw(uint256 assets) external {
        assets = bound(assets, 1, 100_000e6);
        vm.prank(vault);
        try adapter.withdraw(yieldVault, assets) returns (uint256) {
            store.recordWithdraw(assets);
        } catch { }
    }

    function withdrawAll() external {
        vm.prank(vault);
        try adapter.withdrawAll(yieldVault) returns (uint256 out) {
            store.recordWithdraw(out);
        } catch { }
    }
}
