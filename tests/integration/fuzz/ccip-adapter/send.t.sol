// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

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
        bytes32 messageId = ccipAdapter.send{ value: fee + extraValue }(
            destSelector, recipient, address(usdc), amount, address(0), fee, ""
        );

        assertEq(messageId, mockCcipRouter.nextMessageId(), "messageId");
        assertEq(usdc.balanceOf(users.vault), vaultBefore - amount, "vault debit");
        assertEq(address(mockCcipRouter).balance, fee, "fee forwarded");
        // Excess native stays in the adapter, recoverable via rescueETH.
        assertEq(address(ccipAdapter).balance, extraValue, "excess not retained");
        assertZeroAllowance(address(usdc), address(ccipAdapter), address(mockCcipRouter));
    }

    function testFuzz_Send_TokenFee(uint256 amount, uint256 fee) external {
        amount = bound(amount, 1, usdc.balanceOf(users.vault));
        fee = bound(fee, 0, link.balanceOf(users.vault));
        mockCcipRouter.setFee(fee);

        uint64 destSelector = defaults.CCIP_DEST_SELECTOR();
        bytes32 recipient = defaults.BRIDGE_RECIPIENT();
        uint256 usdcBefore = usdc.balanceOf(users.vault);
        uint256 linkBefore = link.balanceOf(users.vault);

        vm.prank(users.vault);
        ccipAdapter.send(destSelector, recipient, address(usdc), amount, address(link), fee, "");

        assertEq(usdc.balanceOf(users.vault), usdcBefore - amount, "usdc debit");
        assertEq(link.balanceOf(users.vault), linkBefore - fee, "link debit");
        assertEq(link.balanceOf(address(mockCcipRouter)), fee, "link fee credited");
        assertZeroAllowance(address(usdc), address(ccipAdapter), address(mockCcipRouter));
        assertZeroAllowance(address(link), address(ccipAdapter), address(mockCcipRouter));
    }

    function testFuzz_Send_FeeTokenEqualsBridgedToken(uint256 amount, uint256 fee) external {
        // Bridge USDC and pay the CCIP fee in USDC: a single amount+fee allowance must cover both
        // the token leg and the fee pull.
        uint256 balance = usdc.balanceOf(users.vault);
        amount = bound(amount, 1, balance / 2);
        fee = bound(fee, 0, balance - amount);
        mockCcipRouter.setFee(fee);

        uint64 destSelector = defaults.CCIP_DEST_SELECTOR();
        bytes32 recipient = defaults.BRIDGE_RECIPIENT();
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        ccipAdapter.send(destSelector, recipient, address(usdc), amount, address(usdc), fee, "");

        // Both the token leg and the fee were pulled from the vault in USDC.
        assertEq(usdc.balanceOf(users.vault), vaultBefore - amount - fee, "vault debit");
        assertEq(usdc.balanceOf(address(mockCcipRouter)), amount + fee, "router credit");
        assertZeroAllowance(address(usdc), address(ccipAdapter), address(mockCcipRouter));
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
        ccipAdapter.send{ value: fee }(destSelector, recipient, address(usdc), amount, address(0), maxFee, "");
    }
}
