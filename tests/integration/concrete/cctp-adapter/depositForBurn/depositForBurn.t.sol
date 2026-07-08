// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { IYoCctpAdapter } from "src/interfaces/IYoCctpAdapter.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract DepositForBurn_CctpAdapter_Integration_Concrete_Test is Integration_Test {
    uint32 private domain;
    bytes32 private recipient;
    uint256 private amount;
    uint256 private maxFee;
    uint32 private threshold;

    function setUp() public override {
        Integration_Test.setUp();
        domain = defaults.CCTP_DEST_DOMAIN();
        recipient = defaults.BRIDGE_RECIPIENT();
        amount = defaults.BRIDGE_AMOUNT();
        maxFee = defaults.BRIDGE_MAX_FEE();
        threshold = defaults.CCTP_FINALITY_THRESHOLD();
    }

    function test_WhenAmountZero() external {
        vm.prank(users.vault);
        vm.expectRevert(IYoCctpAdapter.InvalidAmount.selector);
        cctpAdapter.depositForBurn(0, domain, recipient, maxFee, threshold);
    }

    modifier whenAmountNonZero() {
        _;
    }

    function test_WhenFeeTooHigh() external whenAmountNonZero {
        uint256 cap = (amount * defaults.MAX_FEE_BPS()) / defaults.BPS_DENOMINATOR();
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpAdapter.FeeTooHigh.selector, cap + 1, cap));
        cctpAdapter.depositForBurn(amount, domain, recipient, cap + 1, threshold);
    }

    function test_WhenRouteNotAllowed() external whenAmountNonZero {
        bytes32 badRecipient = bytes32(uint256(0xDEAD)); // not allowlisted

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpAdapter.RouteNotAllowed.selector, domain, badRecipient));
        cctpAdapter.depositForBurn(amount, domain, badRecipient, maxFee, threshold);
    }

    function test_WhenRouteAllowed() external whenAmountNonZero {
        uint256 vaultBefore = usdc.balanceOf(users.vault);

        vm.expectEmit(true, true, true, true, address(cctpAdapter));
        emit YoAdapterBase.AdapterAction(
            users.vault,
            address(mockTokenMessenger),
            address(usdc),
            YoAdapterBase.AdapterDirection.Bridge,
            amount
        );

        vm.prank(users.vault);
        uint256 burned = cctpAdapter.depositForBurn(amount, domain, recipient, maxFee, threshold);

        // it should return amount
        assertEq(burned, amount, "return value");
        // it should pull amount of usdc from the vault
        assertEq(usdc.balanceOf(users.vault), vaultBefore - amount, "vault not debited");
        assertEq(usdc.balanceOf(address(mockTokenMessenger)), amount, "messenger not credited");
        // it should forward the params to the tokenMessenger
        (
            uint256 fAmount,
            uint32 fDomain,
            bytes32 fRecipient,
            address fBurnToken,
            bytes32 fCaller,
            uint256 fMaxFee,
            uint32 fThreshold
        ) = mockTokenMessenger.last();
        assertEq(fAmount, amount, "amount");
        assertEq(fDomain, domain, "domain");
        assertEq(fRecipient, recipient, "recipient");
        // it should forward burnToken as usdc
        assertEq(fBurnToken, address(usdc), "burnToken not usdc");
        // destinationCaller is forced to bytes32(0) by the adapter (permissionless mint).
        assertEq(fCaller, bytes32(0), "caller not forced to zero");
        assertEq(fMaxFee, maxFee, "maxFee");
        assertEq(fThreshold, threshold, "threshold");
        // it should reset tokenMessenger allowance to zero / leave zero usdc in the adapter
        assertZeroAllowance(address(usdc), address(cctpAdapter), address(mockTokenMessenger));
        assertZeroBalance(address(usdc), address(cctpAdapter));
    }
}
