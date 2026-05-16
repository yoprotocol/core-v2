// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { MockLidoWithdrawalQueue } from "../../../../mocks/MockLidoWithdrawalQueue.sol";
import { Integration_Test } from "../../../Integration.t.sol";

contract ClaimUnstakeLidoIntegrationConcreteTest is Integration_Test {
    function setUp() public override {
        super.setUp();
        mockStETH.mintForTest(users.vault, 100 ether);
    }

    function _seedRequest(uint256 amount) internal returns (uint256 requestId) {
        vm.prank(users.vault);
        requestId = lidoAdapter.requestUnstake(amount);
    }

    function test_RevertGiven_VaultDoesNotOwnRequest() external whenCallerVault {
        // Eve queues her own request, vault tries to claim it.
        mockStETH.mintForTest(users.eve, 10 ether);
        vm.startPrank(users.eve);
        mockStETH.approve(address(lidoAdapter), type(uint256).max);
        mockLidoQueue.setApprovalForAll(address(lidoAdapter), true);
        uint256 eveRequestId = lidoAdapter.requestUnstake(1 ether);
        vm.stopPrank();

        mockLidoQueue.finalize(eveRequestId, uint128(1 ether));

        // Both eve and the vault have set approval-for-all on the adapter (see setUp + the eve block
        // above), so the adapter IS authorized to move eve's NFT — but `transferFrom(from=vault, ...)`
        // mismatches the actual owner (`eve`), tripping `ERC721IncorrectOwner` after _checkAuthorized.
        vm.prank(users.vault);
        vm.expectPartialRevert(IERC721Errors.ERC721IncorrectOwner.selector);
        lidoAdapter.claimUnstake(eveRequestId);
    }

    function test_RevertGiven_VaultRevokedApprovalForAll() external {
        uint256 requestId = _seedRequest(10 ether);
        mockLidoQueue.finalize(requestId, uint128(10 ether));

        vm.prank(users.vault);
        mockLidoQueue.setApprovalForAll(address(lidoAdapter), false);

        vm.prank(users.vault);
        vm.expectPartialRevert(IERC721Errors.ERC721InsufficientApproval.selector);
        lidoAdapter.claimUnstake(requestId);
    }

    function test_RevertGiven_RequestNotFinalized() external {
        uint256 requestId = _seedRequest(10 ether);
        // No finalize call.
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(MockLidoWithdrawalQueue.NotFinalized.selector, requestId));
        lidoAdapter.claimUnstake(requestId);
    }

    function test_GivenFinalized_ClaimsAndForwardsWETH() external {
        uint256 amount = 10 ether;
        uint256 requestId = _seedRequest(amount);
        mockLidoQueue.finalize(requestId, uint128(amount));

        uint256 wethBefore = mockWETH.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 wethReceived = lidoAdapter.claimUnstake(requestId);

        assertEq(wethReceived, amount, "wethReceived");
        assertEq(mockWETH.balanceOf(users.vault), wethBefore + amount, "vault WETH in");

        // NFT burned (ownerOf reverts).
        vm.expectRevert();
        mockLidoQueue.ownerOf(requestId);

        // Custody invariants.
        assertEq(address(lidoAdapter).balance, 0, "adapter ETH");
        assertEq(mockWETH.balanceOf(address(lidoAdapter)), 0, "adapter WETH");
    }
}
