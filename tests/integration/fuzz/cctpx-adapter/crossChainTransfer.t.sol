// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoCctpxAdapter } from "src/interfaces/IYoCctpxAdapter.sol";

import { MockCrossChainTokenService } from "../../../mocks/MockCrossChainTokenService.sol";
import { CctpxAdapter_Integration_Test } from "../../concrete/cctpx-adapter/CctpxAdapter.t.sol";

contract CrossChainTransfer_CctpxAdapter_Integration_Fuzz_Test is CctpxAdapter_Integration_Test {
    function testFuzz_CrossChainTransfer_PullsAndForwards(
        uint256 transferAmount,
        uint32 destinationDomain,
        address to,
        bool fast,
        uint256 fee,
        uint256 serviceDust
    )
        external
    {
        vm.assume(to != address(0));
        transferAmount = bound(transferAmount, 1, VAULT_EURC);
        fee = bound(fee, 0, MAX_NATIVE_FEE);
        // ETH that earlier callers left in the service must not change what the vault pays.
        serviceDust = bound(serviceDust, 0, 1 ether);
        vm.deal(address(mockService), serviceDust);
        uint32 minFinalityThreshold = fast ? FAST_FINALITY : STANDARD_FINALITY;
        _allowRoute(users.vault, address(cctpxAdapter), address(eurc), destinationDomain, _toBytes32(to));

        vm.prank(users.vault);
        uint256 sent = cctpxAdapter.crossChainTransfer{ value: fee }(
            transferAmount, destinationDomain, to, minFinalityThreshold, _quote(fee)
        );

        assertEq(sent, transferAmount, "return");
        assertEq(eurc.balanceOf(users.vault), VAULT_EURC - transferAmount, "vault debit");
        assertEq(eurc.balanceOf(address(mockTokenManager)), transferAmount, "token manager credit");
        assertEq(users.vault.balance, VAULT_ETH - fee, "vault ETH");
        assertEq(address(mockFeeManager).balance, fee, "fee paid");
        assertEq(address(mockService).balance, serviceDust, "service balance changed");

        MockCrossChainTokenService.LastTransfer memory last = mockService.last();
        assertEq(last.tokenId, TOKEN_ID, "tokenId");
        assertEq(last.amount, transferAmount, "amount");
        assertEq(last.destinationDomain, destinationDomain, "domain");
        assertEq(last.destinationAddress, abi.encodePacked(to), "destinationAddress");
        assertEq(last.destinationCaller, bytes32(0), "destinationCaller");
        assertEq(last.minFinalityThreshold, minFinalityThreshold, "minFinalityThreshold");
        assertEq(last.refundAddress, users.vault, "refundAddress");
        assertFalse(last.autoExecuteHookData, "autoExecuteHookData");
        assertEq(last.hookData.length, 0, "hookData");
        // Custody invariants.
        assertZeroBalance(address(eurc), address(cctpxAdapter));
        assertZeroAllowance(address(eurc), address(cctpxAdapter), address(mockTokenManager));
        assertEq(address(cctpxAdapter).balance, 0, "adapter ETH");
    }

    function testFuzz_CrossChainTransfer_RevertWhen_FinalityThresholdInvalid(uint32 threshold) external {
        vm.assume(threshold != FAST_FINALITY && threshold != STANDARD_FINALITY);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.InvalidFinalityThreshold.selector, threshold));
        cctpxAdapter.crossChainTransfer{ value: FEE }(amount, DEST_DOMAIN, recipient, threshold, _quote(FEE));
    }

    function testFuzz_CrossChainTransfer_RevertWhen_MsgValueAboveCap(uint256 value) external {
        value = bound(value, MAX_NATIVE_FEE + 1, 100 ether);
        vm.deal(users.vault, value);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.NativeFeeTooHigh.selector, value, MAX_NATIVE_FEE));
        cctpxAdapter.crossChainTransfer{ value: value }(
            amount, DEST_DOMAIN, recipient, STANDARD_FINALITY, _quote(value)
        );
    }

    /// @dev The service keeps an excess and covers a shortfall from its own ETH (pre-funded here); the
    ///      adapter reverts either way, with the fee the service charged.
    function testFuzz_CrossChainTransfer_RevertWhen_MsgValueNotQuoteTotal(uint256 fee, uint256 value) external {
        fee = bound(fee, 0, MAX_NATIVE_FEE);
        value = bound(value, 0, MAX_NATIVE_FEE);
        vm.assume(value != fee);
        vm.deal(address(mockService), fee);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.IncorrectNativeFee.selector, value, fee));
        cctpxAdapter.crossChainTransfer{ value: value }(amount, DEST_DOMAIN, recipient, STANDARD_FINALITY, _quote(fee));
    }

    /// @dev Only the allowlisted `(DEST_DOMAIN, recipient)` passes; any other domain or recipient reverts.
    function testFuzz_CrossChainTransfer_RevertWhen_RouteFieldsDiffer(uint32 domain, address to) external {
        vm.assume(to != address(0));
        vm.assume(domain != DEST_DOMAIN || to != recipient);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.RouteNotAllowed.selector, domain, to));
        cctpxAdapter.crossChainTransfer{ value: FEE }(amount, domain, to, STANDARD_FINALITY, _quote(FEE));
    }

    /// @dev Routes are keyed on the calling vault: no other caller can use `users.vault`'s route.
    function testFuzz_CrossChainTransfer_RevertWhen_CallerNotRouteVault(address caller) external {
        vm.assume(caller != users.vault);
        assumeNotForgeAddress(caller);
        vm.deal(caller, FEE);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.RouteNotAllowed.selector, DEST_DOMAIN, recipient));
        cctpxAdapter.crossChainTransfer{ value: FEE }(amount, DEST_DOMAIN, recipient, STANDARD_FINALITY, _quote(FEE));
    }
}
