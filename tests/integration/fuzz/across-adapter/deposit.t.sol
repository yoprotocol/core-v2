// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoAcrossAdapter } from "src/interfaces/IYoAcrossAdapter.sol";

import { Integration_Test } from "../../Integration.t.sol";

contract Deposit_AcrossAdapter_Integration_Fuzz_Test is Integration_Test {
    function testFuzz_Deposit_PullsAndForwards(uint256 inputAmount, address recipient, uint256 destinationId) external {
        inputAmount = bound(inputAmount, 1, usdc.balanceOf(users.vault));

        // Allowlist the fuzzed route so the deposit is permitted (registry keys the recipient as bytes32).
        _allowRoute(
            users.vault, address(acrossAdapter), address(usdc), destinationId, bytes32(uint256(uint160(recipient)))
        );

        IYoAcrossAdapter.DepositParams memory p = IYoAcrossAdapter.DepositParams({
            recipient: recipient,
            inputToken: address(usdc),
            outputToken: address(0),
            inputAmount: inputAmount,
            outputAmount: inputAmount,
            destinationChainId: destinationId,
            exclusiveRelayer: address(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 1 hours),
            exclusivityParameter: 0,
            message: ""
        });

        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 bridged = acrossAdapter.deposit(p);

        assertEq(bridged, inputAmount, "return");
        assertEq(usdc.balanceOf(users.vault), vaultBefore - inputAmount, "vault debit");
        assertEq(mockSpokePool.recipient(), recipient, "recipient forwarded");
        assertEq(mockSpokePool.destinationChainId(), destinationId, "destinationId forwarded");
        assertEq(mockSpokePool.depositor(), address(users.vault), "depositor");
        // Custody invariants.
        assertZeroBalance(address(usdc), address(acrossAdapter));
        assertZeroAllowance(address(usdc), address(acrossAdapter), address(mockSpokePool));
    }

    function testFuzz_Deposit_RevertWhen_RouteNotAllowed(address recipient) external {
        vm.assume(recipient != defaults.BRIDGE_RECIPIENT_ADDR());

        IYoAcrossAdapter.DepositParams memory p = IYoAcrossAdapter.DepositParams({
            recipient: recipient,
            inputToken: address(usdc),
            outputToken: address(usdc),
            inputAmount: defaults.BRIDGE_AMOUNT(),
            outputAmount: defaults.BRIDGE_AMOUNT(),
            destinationChainId: defaults.ACROSS_DEST_CHAIN_ID(),
            exclusiveRelayer: address(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 1 hours),
            exclusivityParameter: 0,
            message: ""
        });

        vm.prank(users.vault);
        vm.expectRevert();
        acrossAdapter.deposit(p);
    }
}
