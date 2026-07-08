// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoCcipAdapter } from "src/interfaces/IYoCcipAdapter.sol";

import { Integration_Test } from "../../Integration.t.sol";

contract Send_CcipAdapter_Integration_Fuzz_Test is Integration_Test {
    function testFuzz_Send_NativeFee(uint256 amount, uint256 fee, uint256 extraValue) external {
        amount = bound(amount, 1, usdc.balanceOf(users.vault));
        fee = bound(fee, 0, 5 ether);
        extraValue = bound(extraValue, 0, 1 ether);
        mockCcipRouter.setFee(fee);
        vm.deal(users.vault, fee + extraValue);

        uint64 destSelector = defaults.CCIP_DEST_SELECTOR();
        bytes32 recipient = defaults.BRIDGE_RECIPIENT();
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        bytes32 messageId =
            ccipAdapter.send{ value: fee + extraValue }(destSelector, recipient, address(usdc), amount, fee, "");

        assertEq(messageId, mockCcipRouter.nextMessageId(), "messageId");
        assertEq(usdc.balanceOf(users.vault), vaultBefore - amount, "vault debit");
        assertEq(address(mockCcipRouter).balance, fee, "fee forwarded");
        // Excess native stays in the adapter, recoverable via rescueETH.
        assertEq(address(ccipAdapter).balance, extraValue, "excess not retained");
        assertZeroAllowance(address(usdc), address(ccipAdapter), address(mockCcipRouter));
    }

    function testFuzz_Send_RevertWhen_RecipientNotEvmAddress(bytes32 dirtyRecipient) external {
        vm.assume(uint256(dirtyRecipient) >> 160 != 0); // has bits above the low 160
        uint64 destSelector = defaults.CCIP_DEST_SELECTOR();
        uint256 amount = defaults.BRIDGE_AMOUNT();
        // Allowlist the dirty recipient so the route check passes and the EVM-address guard is reached.
        _allowRoute(users.vault, address(ccipAdapter), address(usdc), destSelector, dirtyRecipient);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoCcipAdapter.RecipientNotEvmAddress.selector, dirtyRecipient));
        ccipAdapter.send(destSelector, dirtyRecipient, address(usdc), amount, 0, "");
    }

    function testFuzz_Send_RevertWhen_FeeExceedsMax(uint256 fee, uint256 maxFee) external {
        fee = bound(fee, 1, 100 ether);
        maxFee = bound(maxFee, 0, fee - 1);
        mockCcipRouter.setFee(fee);
        vm.deal(users.vault, fee);

        uint64 destSelector = defaults.CCIP_DEST_SELECTOR();
        bytes32 recipient = defaults.BRIDGE_RECIPIENT();
        uint256 amount = defaults.BRIDGE_AMOUNT();

        vm.prank(users.vault);
        vm.expectRevert();
        ccipAdapter.send{ value: fee }(destSelector, recipient, address(usdc), amount, maxFee, "");
    }
}
