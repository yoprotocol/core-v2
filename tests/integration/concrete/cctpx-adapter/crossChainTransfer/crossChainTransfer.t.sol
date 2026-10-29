// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { YoCctpxAdapter } from "src/adapters/cctpx/YoCctpxAdapter.sol";
import { ICrossChainTokenService } from "src/interfaces/external/ICrossChainTokenService.sol";
import { IYoBridgeRouteRegistry } from "src/interfaces/IYoBridgeRouteRegistry.sol";
import { IYoCctpxAdapter } from "src/interfaces/IYoCctpxAdapter.sol";

import { MockCrossChainTokenService } from "../../../../mocks/MockCrossChainTokenService.sol";
import { MockReentrantERC20 } from "../../../../mocks/MockReentrantERC20.sol";
import { CctpxAdapter_Integration_Test } from "../CctpxAdapter.t.sol";

contract CrossChainTransfer_CctpxAdapter_Integration_Concrete_Test is CctpxAdapter_Integration_Test {
    /// @dev ETH that earlier callers' overpayments left in the service.
    uint256 internal constant SERVICE_DUST = 1 ether;

    function test_WhenAmountZero() external {
        vm.prank(users.vault);
        vm.expectRevert(IYoCctpxAdapter.InvalidAmount.selector);
        cctpxAdapter.crossChainTransfer{ value: FEE }(0, DEST_DOMAIN, recipient, STANDARD_FINALITY, _quote(FEE));
    }

    modifier whenAmountNonZero() {
        _;
    }

    function test_WhenRecipientZero() external whenAmountNonZero {
        // Allowlist the zero recipient so only the adapter's own check can reject it.
        _allowRoute(users.vault, address(cctpxAdapter), address(eurc), DEST_DOMAIN, bytes32(0));

        vm.prank(users.vault);
        vm.expectRevert(IYoCctpxAdapter.InvalidRecipient.selector);
        cctpxAdapter.crossChainTransfer{ value: FEE }(amount, DEST_DOMAIN, address(0), STANDARD_FINALITY, _quote(FEE));
    }

    modifier whenRecipientNonZero() {
        _;
    }

    function test_WhenMinFinalityThresholdNotFastOrStandard() external whenAmountNonZero whenRecipientNonZero {
        // 1500 is between the tiers: it would pay the fast fee for an attestation at finality.
        uint32 threshold = 1500;

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.InvalidFinalityThreshold.selector, threshold));
        cctpxAdapter.crossChainTransfer{ value: FEE }(amount, DEST_DOMAIN, recipient, threshold, _quote(FEE));
    }

    modifier whenMinFinalityThresholdFastOrStandard() {
        _;
    }

    function test_WhenMsgValueAboveMaxNativeFee()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
    {
        uint256 value = MAX_NATIVE_FEE + 1;

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.NativeFeeTooHigh.selector, value, MAX_NATIVE_FEE));
        cctpxAdapter.crossChainTransfer{ value: value }(
            amount, DEST_DOMAIN, recipient, STANDARD_FINALITY, _quote(value)
        );
    }

    modifier whenMsgValueAtMostMaxNativeFee() {
        _;
    }

    function test_WhenCallerIsNotTheRouteVault()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
        whenMsgValueAtMostMaxNativeFee
    {
        vm.deal(users.eve, FEE);
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.RouteNotAllowed.selector, DEST_DOMAIN, recipient));
        cctpxAdapter.crossChainTransfer{ value: FEE }(amount, DEST_DOMAIN, recipient, STANDARD_FINALITY, _quote(FEE));
    }

    function test_WhenRouteIsForAnotherAdapter()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
        whenMsgValueAtMostMaxNativeFee
    {
        // The same route key, but for the CCTP adapter.
        _revokeRoute();
        _allowRoute(users.vault, address(cctpAdapter), address(eurc), DEST_DOMAIN, _toBytes32(recipient));

        _expectRouteNotAllowed(DEST_DOMAIN, recipient);
    }

    function test_WhenRouteIsForAnotherToken()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
        whenMsgValueAtMostMaxNativeFee
    {
        // The same route key, but for USDC.
        _revokeRoute();
        _allowRoute(users.vault, address(cctpxAdapter), address(usdc), DEST_DOMAIN, _toBytes32(recipient));

        _expectRouteNotAllowed(DEST_DOMAIN, recipient);
    }

    function test_WhenDestinationDomainIsNotTheRouteDomain()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
        whenMsgValueAtMostMaxNativeFee
    {
        _expectRouteNotAllowed(OTHER_DOMAIN, recipient);
    }

    function test_WhenRecipientIsNotTheRouteRecipient()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
        whenMsgValueAtMostMaxNativeFee
    {
        _expectRouteNotAllowed(DEST_DOMAIN, address(0xDEAD));
    }

    function test_WhenRoutePinsAnOutputToken()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
        whenMsgValueAtMostMaxNativeFee
    {
        // CCTPx mints the same token, so the adapter checks the unpinned (`bytes32(0)`) route only.
        _revokeRoute();
        _allowRoute(
            users.vault,
            address(cctpxAdapter),
            address(eurc),
            DEST_DOMAIN,
            _toBytes32(recipient),
            _toBytes32(address(eurc))
        );

        _expectRouteNotAllowed(DEST_DOMAIN, recipient);
    }

    modifier whenRouteAllowed() {
        _;
    }

    function test_WhenMsgValueAboveQuoteTotal()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
        whenMsgValueAtMostMaxNativeFee
        whenRouteAllowed
    {
        // The service would keep the excess, so the adapter rejects an overpayment instead of losing it.
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.IncorrectNativeFee.selector, FEE + 1, FEE));
        cctpxAdapter.crossChainTransfer{ value: FEE + 1 }(
            amount, DEST_DOMAIN, recipient, STANDARD_FINALITY, _quote(FEE)
        );
    }

    modifier whenMsgValueBelowQuoteTotal() {
        _;
    }

    function test_GivenServiceCannotCoverTheShortfall()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
        whenMsgValueAtMostMaxNativeFee
        whenRouteAllowed
        whenMsgValueBelowQuoteTotal
    {
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(MockCrossChainTokenService.FeePaymentFailed.selector, FEE, FEE - 1));
        cctpxAdapter.crossChainTransfer{ value: FEE - 1 }(
            amount, DEST_DOMAIN, recipient, STANDARD_FINALITY, _quote(FEE)
        );
    }

    function test_GivenServiceCoversTheShortfallFromItsOwnBalance()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
        whenMsgValueAtMostMaxNativeFee
        whenRouteAllowed
        whenMsgValueBelowQuoteTotal
    {
        // The service would pay the 1 wei shortfall out of other callers' ETH.
        vm.deal(address(mockService), SERVICE_DUST);

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.IncorrectNativeFee.selector, FEE - 1, FEE));
        cctpxAdapter.crossChainTransfer{ value: FEE - 1 }(
            amount, DEST_DOMAIN, recipient, STANDARD_FINALITY, _quote(FEE)
        );
    }

    modifier whenMsgValueEqualsQuoteTotal() {
        _;
    }

    function test_WhenReenteredThroughTokenTransferHook()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
        whenMsgValueAtMostMaxNativeFee
        whenRouteAllowed
        whenMsgValueEqualsQuoteTotal
    {
        // An adapter pinned to a token that re-enters it from `transferFrom`.
        MockReentrantERC20 rent = new MockReentrantERC20();
        bytes32 rentId = keccak256("RENT");
        mockService.register(rentId, IERC20(address(rent)));
        YoCctpxAdapter reentrantAdapter = new YoCctpxAdapter(
            ICrossChainTokenService(address(mockService)),
            IERC20(address(rent)),
            rentId,
            IYoBridgeRouteRegistry(address(routeRegistry)),
            MAX_NATIVE_FEE,
            yoRegistry
        );
        _allowRoute(users.vault, address(reentrantAdapter), address(rent), DEST_DOMAIN, _toBytes32(recipient));
        rent.mint(users.vault, amount);
        vm.prank(users.vault);
        rent.approve(address(reentrantAdapter), type(uint256).max);

        rent.arm(
            address(reentrantAdapter),
            abi.encodeCall(
                IYoCctpxAdapter.crossChainTransfer, (1, DEST_DOMAIN, recipient, STANDARD_FINALITY, _quote(0))
            )
        );

        vm.prank(users.vault);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        reentrantAdapter.crossChainTransfer{ value: FEE }(
            amount, DEST_DOMAIN, recipient, STANDARD_FINALITY, _quote(FEE)
        );
    }

    function test_WhenMsgValueEqualsMaxNativeFee()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
        whenMsgValueAtMostMaxNativeFee
        whenRouteAllowed
        whenMsgValueEqualsQuoteTotal
    {
        vm.prank(users.vault);
        uint256 sent = cctpxAdapter.crossChainTransfer{ value: MAX_NATIVE_FEE }(
            amount, DEST_DOMAIN, recipient, STANDARD_FINALITY, _quote(MAX_NATIVE_FEE)
        );

        // it should transfer
        assertEq(sent, amount, "return value");
        assertEq(address(mockFeeManager).balance, MAX_NATIVE_FEE, "fee not paid");
        assertEq(eurc.balanceOf(address(mockTokenManager)), amount, "token manager not credited");
    }

    function test_GivenServiceHoldsETHFromEarlierCallers()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
        whenMsgValueAtMostMaxNativeFee
        whenRouteAllowed
        whenMsgValueEqualsQuoteTotal
    {
        vm.deal(address(mockService), SERVICE_DUST);

        vm.prank(users.vault);
        uint256 sent = cctpxAdapter.crossChainTransfer{ value: FEE }(
            amount, DEST_DOMAIN, recipient, STANDARD_FINALITY, _quote(FEE)
        );

        // it should transfer and leave the service balance unchanged
        assertEq(sent, amount, "return value");
        assertEq(address(mockService).balance, SERVICE_DUST, "service balance changed");
        assertEq(address(mockFeeManager).balance, FEE, "fee not paid");
    }

    function test_GivenTokenManagerPullsLessThanApproved()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
        whenMsgValueAtMostMaxNativeFee
        whenRouteAllowed
        whenMsgValueEqualsQuoteTotal
    {
        // The token manager leaves `unpulled` of the allowance that the adapter gave it.
        uint256 unpulled = 1;
        mockTokenManager.setShortfall(unpulled);

        vm.prank(users.vault);
        cctpxAdapter.crossChainTransfer{ value: FEE }(amount, DEST_DOMAIN, recipient, STANDARD_FINALITY, _quote(FEE));

        // it should reset the token manager allowance to zero
        assertZeroAllowance(address(eurc), address(cctpxAdapter), address(mockTokenManager));
        // it should leave the unpulled tokens in the adapter for rescue
        assertEq(eurc.balanceOf(address(cctpxAdapter)), unpulled, "adapter balance");
        uint256 vaultBefore = eurc.balanceOf(users.vault);
        vm.prank(users.vault);
        assertEq(cctpxAdapter.rescue(eurc), unpulled, "rescued");
        assertEq(eurc.balanceOf(users.vault), vaultBefore + unpulled, "vault balance");
    }

    function test_WhenNotReentered()
        external
        whenAmountNonZero
        whenRecipientNonZero
        whenMinFinalityThresholdFastOrStandard
        whenMsgValueAtMostMaxNativeFee
        whenRouteAllowed
        whenMsgValueEqualsQuoteTotal
    {
        bytes memory quote = _quote(FEE);
        uint256 vaultBefore = eurc.balanceOf(users.vault);

        vm.expectEmit(true, true, true, true, address(cctpxAdapter));
        emit YoAdapterBase.AdapterAction(
            users.vault,
            address(mockService),
            address(eurc),
            YoAdapterBase.AdapterDirection.Bridge,
            amount
        );

        vm.prank(users.vault);
        uint256 sent =
            cctpxAdapter.crossChainTransfer{ value: FEE }(amount, DEST_DOMAIN, recipient, FAST_FINALITY, quote);

        // it should return amount
        assertEq(sent, amount, "return value");
        // it should pull amount from the vault
        assertEq(eurc.balanceOf(users.vault), vaultBefore - amount, "vault not debited");
        // it should credit amount to the token manager
        assertEq(eurc.balanceOf(address(mockTokenManager)), amount, "token manager not credited");

        MockCrossChainTokenService.LastTransfer memory last = mockService.last();
        assertEq(mockService.callCount(), 1, "call count");
        assertEq(last.caller, address(cctpxAdapter), "caller");
        // it should forward tokenId amount and destination domain
        assertEq(last.tokenId, TOKEN_ID, "tokenId");
        assertEq(last.amount, amount, "amount");
        assertEq(last.destinationDomain, DEST_DOMAIN, "destinationDomain");
        // it should forward the recipient as its raw 20 bytes
        assertEq(last.destinationAddress.length, 20, "destinationAddress length");
        assertEq(last.destinationAddress, abi.encodePacked(recipient), "destinationAddress");
        // it should forward a zero destination caller
        assertEq(last.destinationCaller, bytes32(0), "destinationCaller");
        // it should forward minFinalityThreshold
        assertEq(last.minFinalityThreshold, FAST_FINALITY, "minFinalityThreshold");
        // it should forward the signed quote with the vault as refund address
        assertEq(last.signedQuote, quote, "signedQuote");
        assertEq(last.refundAddress, users.vault, "refundAddress");
        // it should not request a destination hook
        assertFalse(last.autoExecuteHookData, "autoExecuteHookData");
        assertEq(last.hookData.length, 0, "hookData");
        // it should pay msg value as the fee
        assertEq(last.value, FEE, "value");
        assertEq(address(mockFeeManager).balance, FEE, "fee not paid");
        assertEq(address(mockService).balance, 0, "service kept ETH");
        assertEq(users.vault.balance, VAULT_ETH - FEE, "vault ETH");
        // it should reset the token manager allowance to zero
        assertZeroAllowance(address(eurc), address(cctpxAdapter), address(mockTokenManager));
        // it should leave zero token and zero ETH in the adapter
        assertZeroBalance(address(eurc), address(cctpxAdapter));
        assertEq(address(cctpxAdapter).balance, 0, "adapter ETH");
    }

    function _revokeRoute() private {
        vm.prank(users.owner);
        routeRegistry.setRoute(
            users.vault, address(cctpxAdapter), address(eurc), DEST_DOMAIN, _toBytes32(recipient), bytes32(0), false
        );
    }

    function _expectRouteNotAllowed(uint32 domain, address to) private {
        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.RouteNotAllowed.selector, domain, to));
        cctpxAdapter.crossChainTransfer{ value: FEE }(amount, domain, to, STANDARD_FINALITY, _quote(FEE));
    }
}
