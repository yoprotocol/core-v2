// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/src/Test.sol";

import { YoLidoAdapter } from "src/adapters/lido/YoLidoAdapter.sol";

import { MockLidoWithdrawalQueue } from "../../mocks/MockLidoWithdrawalQueue.sol";
import { MockStETH } from "../../mocks/MockStETH.sol";
import { MockWETH9 } from "../../mocks/MockWETH9.sol";
import { Store } from "../stores/Store.sol";

contract LidoAdapterHandler is Test {
    YoLidoAdapter internal adapter;
    address internal vault;
    MockWETH9 internal mockWETH;
    MockStETH internal mockStETH;
    MockLidoWithdrawalQueue internal mockQueue;
    Store internal store;

    uint256[] internal openRequestIds;

    constructor(
        YoLidoAdapter _adapter,
        address _vault,
        MockWETH9 _mockWETH,
        MockStETH _mockStETH,
        MockLidoWithdrawalQueue _mockQueue,
        Store _store
    ) {
        adapter = _adapter;
        vault = _vault;
        mockWETH = _mockWETH;
        mockStETH = _mockStETH;
        mockQueue = _mockQueue;
        store = _store;
    }

    function stake(uint256 amount) external {
        amount = bound(amount, 1, 1000 ether);
        // Mint WETH to the vault by depositing ETH on behalf of vault.
        vm.deal(vault, vault.balance + amount);
        vm.prank(vault);
        mockWETH.deposit{ value: amount }();

        vm.prank(vault);
        try adapter.stake(amount) {
            store.recordSupply(amount);
        } catch { }
    }

    function requestUnstake(uint256 amount) external {
        uint256 bal = mockStETH.balanceOf(vault);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(vault);
        try adapter.requestUnstake(amount) returns (uint256 requestId) {
            openRequestIds.push(requestId);
        } catch { }
    }

    function claimUnstake(uint256 seed) external {
        if (openRequestIds.length == 0) return;
        uint256 idx = seed % openRequestIds.length;
        uint256 requestId = openRequestIds[idx];

        (uint128 amount, uint128 finalizedEth,) = mockQueue.requests(requestId);
        if (finalizedEth == 0) {
            // Finalize at face value so the claim can succeed.
            vm.deal(address(mockQueue), address(mockQueue).balance + amount);
            mockQueue.finalize(requestId, amount);
        }

        vm.prank(vault);
        try adapter.claimUnstake(requestId) returns (uint256 out) {
            store.recordWithdraw(out);
            // Swap-remove to keep the array compact.
            openRequestIds[idx] = openRequestIds[openRequestIds.length - 1];
            openRequestIds.pop();
        } catch { }
    }
}
