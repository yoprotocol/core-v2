// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { IYoAcrossAdapter } from "src/interfaces/IYoAcrossAdapter.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract Deposit_AcrossAdapter_Integration_Concrete_Test is Integration_Test {
    function _params() internal view returns (IYoAcrossAdapter.DepositParams memory p) {
        p = IYoAcrossAdapter.DepositParams({
            recipient: defaults.BRIDGE_RECIPIENT(),
            inputToken: address(usdc),
            outputToken: bytes32(uint256(uint160(address(usdc)))),
            inputAmount: defaults.BRIDGE_AMOUNT(),
            outputAmount: defaults.BRIDGE_AMOUNT() - 1e6,
            destinationChainId: defaults.ACROSS_DEST_CHAIN_ID(),
            exclusiveRelayer: bytes32(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 1 hours),
            exclusivityDeadline: 0,
            message: ""
        });
    }

    function test_WhenInputAmountZero() external {
        IYoAcrossAdapter.DepositParams memory p = _params();
        p.inputAmount = 0;

        vm.prank(users.vault);
        vm.expectRevert(IYoAcrossAdapter.InvalidAmount.selector);
        acrossAdapter.deposit(p);
    }

    modifier whenInputAmountNonZero() {
        _;
    }

    function test_WhenRouteNotAllowed() external whenInputAmountNonZero {
        IYoAcrossAdapter.DepositParams memory p = _params();
        p.recipient = bytes32(uint256(0xDEAD)); // not allowlisted

        vm.prank(users.vault);
        vm.expectRevert(
            abi.encodeWithSelector(
                IYoAcrossAdapter.RouteNotAllowed.selector, address(usdc), defaults.ACROSS_DEST_CHAIN_ID(), p.recipient
            )
        );
        acrossAdapter.deposit(p);
    }

    function test_WhenRouteAllowed() external whenInputAmountNonZero {
        IYoAcrossAdapter.DepositParams memory p = _params();
        // Non-empty message + a non-canonical length (not a multiple of 32) to exercise the hand-built
        // dynamic-tail encoding and its right-padding.
        p.message = hex"deadbeefcafe";
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.expectEmit(true, true, true, true, address(acrossAdapter));
        emit YoAdapterBase.AdapterAction(
            users.vault,
            address(mockSpokePool),
            address(usdc),
            YoAdapterBase.AdapterDirection.Bridge,
            p.inputAmount
        );

        vm.prank(users.vault);
        uint256 bridged = acrossAdapter.deposit(p);

        // it should return inputAmount
        assertEq(bridged, p.inputAmount, "return value");
        // it should pull inputAmount from the vault
        assertEq(usdc.balanceOf(users.vault), vaultBefore - p.inputAmount, "vault not debited");
        assertEq(usdc.balanceOf(address(mockSpokePool)), p.inputAmount, "spokePool not credited");
        // it should forward depositor as the vault
        assertEq(mockSpokePool.depositor(), bytes32(uint256(uint160(address(users.vault)))), "depositor not vault");
        // it should forward the params to the spokePool (incl. amounts, timestamps, and the dynamic message)
        assertEq(mockSpokePool.recipient(), p.recipient, "recipient mismatch");
        assertEq(mockSpokePool.inputToken(), bytes32(uint256(uint160(address(usdc)))), "inputToken mismatch");
        assertEq(mockSpokePool.outputToken(), p.outputToken, "outputToken mismatch");
        assertEq(mockSpokePool.inputAmount(), p.inputAmount, "inputAmount mismatch");
        assertEq(mockSpokePool.outputAmount(), p.outputAmount, "outputAmount mismatch");
        assertEq(mockSpokePool.destinationChainId(), p.destinationChainId, "destinationChainId mismatch");
        assertEq(mockSpokePool.exclusiveRelayer(), p.exclusiveRelayer, "exclusiveRelayer mismatch");
        assertEq(mockSpokePool.quoteTimestamp(), p.quoteTimestamp, "quoteTimestamp mismatch");
        assertEq(mockSpokePool.fillDeadline(), p.fillDeadline, "fillDeadline mismatch");
        assertEq(mockSpokePool.exclusivityDeadline(), p.exclusivityDeadline, "exclusivityDeadline mismatch");
        assertEq(mockSpokePool.message(), p.message, "message mismatch");
        // it should append the Across referral tag (delimiter 0x1dc0de + integrator id 0x0088)
        bytes memory cd = mockSpokePool.lastCalldata();
        bytes memory tag = hex"1dc0de0088";
        for (uint256 i = 0; i < tag.length; ++i) {
            assertEq(cd[cd.length - tag.length + i], tag[i], "referral tag not appended");
        }
        // it should reset spokePool allowance to zero / leave zero inputToken in the adapter
        assertZeroAllowance(address(usdc), address(acrossAdapter), address(mockSpokePool));
        assertZeroBalance(address(usdc), address(acrossAdapter));
    }
}
