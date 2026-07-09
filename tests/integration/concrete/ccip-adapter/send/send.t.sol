// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { IYoCcipAdapter } from "src/interfaces/IYoCcipAdapter.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract Send_CcipAdapter_Integration_Concrete_Test is Integration_Test {
    uint64 private destSelector;
    bytes32 private recipient;
    uint256 private amount;

    function setUp() public override {
        Integration_Test.setUp();
        destSelector = defaults.CCIP_DEST_SELECTOR();
        recipient = defaults.BRIDGE_RECIPIENT();
        amount = defaults.BRIDGE_AMOUNT();
        vm.deal(users.vault, 10 ether);
    }

    function test_WhenAmountZero() external {
        vm.prank(users.vault);
        vm.expectRevert(IYoCcipAdapter.InvalidAmount.selector);
        ccipAdapter.send(destSelector, recipient, address(usdc), 0, 0, "");
    }

    modifier whenAmountNonZero() {
        _;
    }

    function test_WhenRouteNotAllowed() external whenAmountNonZero {
        bytes32 badRecipient = bytes32(uint256(0xDEAD));
        vm.prank(users.vault);
        vm.expectRevert(
            abi.encodeWithSelector(IYoCcipAdapter.RouteNotAllowed.selector, address(usdc), destSelector, badRecipient)
        );
        ccipAdapter.send(destSelector, badRecipient, address(usdc), amount, 0, "");
    }

    modifier whenRouteAllowed() {
        _;
    }

    function test_WhenQuotedFeeExceedsMaxFee() external whenAmountNonZero whenRouteAllowed {
        uint256 fee = defaults.CCIP_FEE();
        mockCcipRouter.setFee(fee);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoCcipAdapter.FeeExceedsMax.selector, fee, 1));
        ccipAdapter.send{ value: fee }(destSelector, recipient, address(usdc), amount, 1, "");
    }

    modifier whenQuotedFeeWithinMaxFee() {
        _;
    }

    function test_WhenMsgValueBelowFee() external whenAmountNonZero whenRouteAllowed whenQuotedFeeWithinMaxFee {
        uint256 fee = defaults.CCIP_FEE();
        mockCcipRouter.setFee(fee);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoCcipAdapter.IncorrectNativeFee.selector, fee - 1, fee));
        ccipAdapter.send{ value: fee - 1 }(destSelector, recipient, address(usdc), amount, fee, "");
    }

    function test_WhenMsgValueAtLeastFee() external whenAmountNonZero whenRouteAllowed whenQuotedFeeWithinMaxFee {
        uint256 fee = defaults.CCIP_FEE();
        mockCcipRouter.setFee(fee);
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.expectEmit(true, true, true, true, address(ccipAdapter));
        emit YoAdapterBase.AdapterAction(
            users.vault,
            address(mockCcipRouter),
            address(usdc),
            YoAdapterBase.AdapterDirection.Bridge,
            amount
        );

        vm.prank(users.vault);
        bytes32 messageId = ccipAdapter.send{ value: fee }(destSelector, recipient, address(usdc), amount, fee, "");

        // it should return the messageId
        assertEq(messageId, mockCcipRouter.nextMessageId(), "messageId");
        // it should pull amount from the vault
        assertEq(usdc.balanceOf(users.vault), vaultBefore - amount, "vault not debited");
        assertEq(usdc.balanceOf(address(mockCcipRouter)), amount, "router not credited");
        assertEq(address(mockCcipRouter).balance, fee, "native fee not forwarded");
        // it should reset router allowance to zero
        assertZeroAllowance(address(usdc), address(ccipAdapter), address(mockCcipRouter));
        assertZeroBalance(address(usdc), address(ccipAdapter));
    }
}
