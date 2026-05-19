// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IYoSwapAdapter } from "src/interfaces/IYoSwapAdapter.sol";
import { IYoSwapOracle } from "src/interfaces/IYoSwapOracle.sol";

import { MockOneInchRouter } from "../../../../mocks/MockOneInchRouter.sol";
import { MockReentrantERC20 } from "../../../../mocks/MockReentrantERC20.sol";
import { Integration_Test } from "../../../Integration.t.sol";

contract SwapIntegrationConcreteTest is Integration_Test {
    /// @dev Calldata that drives `MockOneInchRouter.execute(amountIn)`.
    function _execCalldata(uint256 amountIn) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(MockOneInchRouter.execute.selector, amountIn);
    }

    /// @dev Standard happy-path setup: aggregator delivers `expectedOut` of USDT to the recipient.
    function _armAggregator(uint256 expectedOut, address recipient) internal {
        mockAggregator.setSwap(address(usdc), address(usdt), expectedOut, recipient);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  REVERT BRANCHES
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_DeadlineExpired() external whenCallerVault {
        uint256 expired = block.timestamp - 1;
        // Deadline check runs before the amountIn-zero guard — passing zero amountIn must still
        // surface as DeadlineExpired, locking the ordering.
        vm.expectRevert(abi.encodeWithSelector(IYoSwapAdapter.DeadlineExpired.selector, expired, block.timestamp));
        swapAdapter.swap(address(usdc), address(usdt), 0, 0, expired, _execCalldata(0));
    }

    function test_RevertWhen_AmountInZero() external whenCallerVault {
        vm.expectRevert(IYoSwapAdapter.InvalidAmount.selector);
        swapAdapter.swap(address(usdc), address(usdt), 0, 0, type(uint256).max, _execCalldata(0));
    }

    function test_RevertWhen_PairNotAllowed() external whenCallerVault whenAmountNotZero {
        // USDT -> USDC is not allowlisted (only the forward direction is).
        uint256 amountIn = defaults.SWAP_AMOUNT_IN();
        vm.expectRevert(abi.encodeWithSelector(IYoSwapAdapter.PairNotAllowed.selector, address(usdt), address(usdc)));
        swapAdapter.swap(address(usdt), address(usdc), amountIn, 0, type(uint256).max, _execCalldata(amountIn));
    }

    function test_RevertWhen_OracleUnknownPair() external whenCallerVault whenAmountNotZero whenPairAllowed {
        mockOracle.setUnknown(address(usdc), address(usdt), true);
        uint256 amountIn = defaults.SWAP_AMOUNT_IN();
        vm.expectRevert(abi.encodeWithSelector(IYoSwapOracle.UnknownPair.selector, address(usdc), address(usdt)));
        swapAdapter.swap(address(usdc), address(usdt), amountIn, 0, type(uint256).max, _execCalldata(amountIn));
    }

    function test_RevertWhen_OracleStale() external whenCallerVault whenAmountNotZero whenPairAllowed {
        mockOracle.setStale(address(usdc), address(usdt), true);
        uint256 amountIn = defaults.SWAP_AMOUNT_IN();
        vm.expectRevert(abi.encodeWithSelector(IYoSwapOracle.StalePrice.selector, address(usdc)));
        swapAdapter.swap(address(usdc), address(usdt), amountIn, 0, type(uint256).max, _execCalldata(amountIn));
    }

    function test_RevertWhen_SlippageTooLow()
        external
        whenCallerVault
        whenAmountNotZero
        whenPairAllowed
        whenOracleQuoteAvailable
    {
        uint256 amountIn = defaults.SWAP_AMOUNT_IN();
        // Oracle returns 1:1, slippage cap is 50 bps. Floor = amountIn * (10000 - 50) / 10000.
        uint256 floor =
            (amountIn * (defaults.BPS_DENOMINATOR() - defaults.MAX_SLIPPAGE_BPS())) / defaults.BPS_DENOMINATOR();
        uint256 minOutBelowFloor = floor - 1;

        vm.expectRevert(abi.encodeWithSelector(IYoSwapAdapter.SlippageTooLow.selector, minOutBelowFloor, floor));
        swapAdapter.swap(
            address(usdc), address(usdt), amountIn, minOutBelowFloor, type(uint256).max, _execCalldata(amountIn)
        );
    }

    function test_RevertWhen_VaultHasNotApprovedAdapter()
        external
        whenAmountNotZero
        whenPairAllowed
        whenOracleQuoteAvailable
    {
        // Revoke the default approval set in Integration_Test.setUp(). `whenCallerVault` is omitted
        // so we can switch contexts; pranking inline below.
        vm.prank(users.vault);
        usdc.approve(address(swapAdapter), 0);

        uint256 amountIn = defaults.SWAP_AMOUNT_IN();
        _armAggregator(amountIn, address(swapAdapter));
        vm.prank(users.vault);
        vm.expectRevert();
        swapAdapter.swap(address(usdc), address(usdt), amountIn, amountIn, type(uint256).max, _execCalldata(amountIn));
    }

    function test_RevertWhen_Reentered() external whenAmountNotZero {
        // Use a reentrant token as `tokenIn`. Allowlist the pair, configure the oracle, then arm
        // the token to call back into the adapter during `transferFrom`.
        MockReentrantERC20 rent = new MockReentrantERC20();
        _allowPair(users.vault, address(rent), address(usdt));
        mockOracle.setQuote(address(rent), address(usdt), defaults.ORACLE_QUOTE_1_TO_1());

        rent.mint(users.vault, 1000e6);
        vm.prank(users.vault);
        rent.approve(address(swapAdapter), type(uint256).max);

        uint256 amountIn = 100e6;
        bytes memory payload = abi.encodeCall(
            IYoSwapAdapter.swap, (address(rent), address(usdt), 1, 0, type(uint256).max, _execCalldata(1))
        );
        rent.arm(address(swapAdapter), payload);

        vm.prank(users.vault);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        swapAdapter.swap(address(rent), address(usdt), amountIn, amountIn, type(uint256).max, _execCalldata(amountIn));
    }

    function test_RevertWhen_AggregatorCallReverts()
        external
        whenCallerVault
        whenAmountNotZero
        whenPairAllowed
        whenOracleQuoteAvailable
    {
        uint256 amountIn = defaults.SWAP_AMOUNT_IN();
        _armAggregator(amountIn, address(swapAdapter));
        // Encode calldata that doesn't match any function on `MockOneInchRouter`.
        bytes memory bogus = abi.encodeWithSignature("nonexistent(uint256)", amountIn);
        vm.expectRevert();
        swapAdapter.swap(address(usdc), address(usdt), amountIn, amountIn, type(uint256).max, bogus);
    }

    function test_RevertGiven_InsufficientOutput()
        external
        whenCallerVault
        whenAmountNotZero
        whenPairAllowed
        whenOracleQuoteAvailable
    {
        uint256 amountIn = defaults.SWAP_AMOUNT_IN();
        // Aggregator delivers half of what the operator asked for.
        uint256 actualOut = amountIn / 2;
        _armAggregator(actualOut, address(swapAdapter));

        vm.expectRevert(abi.encodeWithSelector(IYoSwapAdapter.InsufficientOutput.selector, actualOut, amountIn));
        swapAdapter.swap(address(usdc), address(usdt), amountIn, amountIn, type(uint256).max, _execCalldata(amountIn));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   HAPPY-PATH
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenCleanOutput_PullsSweepsAndCleansUp()
        external
        whenCallerVault
        whenAmountNotZero
        whenPairAllowed
        whenOracleQuoteAvailable
    {
        uint256 amountIn = defaults.SWAP_AMOUNT_IN();
        uint256 expectedOut = amountIn; // 1:1 quote

        _armAggregator(expectedOut, address(swapAdapter));

        uint256 vaultUsdcBefore = usdc.balanceOf(users.vault);
        uint256 vaultUsdtBefore = usdt.balanceOf(users.vault);

        uint256 amountOut = swapAdapter.swap(
            address(usdc), address(usdt), amountIn, expectedOut, type(uint256).max, _execCalldata(amountIn)
        );

        assertEq(amountOut, expectedOut, "amountOut return");
        assertEq(usdc.balanceOf(users.vault), vaultUsdcBefore - amountIn, "vault USDC out");
        assertEq(usdt.balanceOf(users.vault), vaultUsdtBefore + expectedOut, "vault USDT in");

        assertZeroBalance(address(usdc), address(swapAdapter));
        assertZeroBalance(address(usdt), address(swapAdapter));
        assertZeroAllowance(address(usdc), address(swapAdapter), address(mockAggregator));
    }

    /*//////////////////////////////////////////////////////////////////////////
                              OPERATOR_TRUSTED MODE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev When the pair is in OPERATOR_TRUSTED mode, the adapter must skip the oracle floor
    ///      entirely. Even with a missing oracle config (`UnknownPair`), the swap should succeed
    ///      as long as `minOut` is satisfied post-swap.
    function test_GivenOperatorTrusted_BypassesOracleFloor() external whenAmountNotZero {
        // Switch USDC→USDT pair to OPERATOR_TRUSTED.
        _allowPairTrusted(users.vault, address(usdc), address(usdt));
        // Deliberately wipe the oracle for the pair to prove the floor isn't consulted.
        mockOracle.setUnknown(address(usdc), address(usdt), true);

        uint256 amountIn = defaults.SWAP_AMOUNT_IN();
        uint256 expectedOut = amountIn;
        _armAggregator(expectedOut, address(swapAdapter));

        uint256 vaultUsdtBefore = usdt.balanceOf(users.vault);
        vm.prank(users.vault);
        uint256 amountOut = swapAdapter.swap(
            address(usdc), address(usdt), amountIn, expectedOut, type(uint256).max, _execCalldata(amountIn)
        );

        assertEq(amountOut, expectedOut, "amountOut return");
        assertEq(usdt.balanceOf(users.vault), vaultUsdtBefore + expectedOut, "vault USDT in");
    }

    /// @dev `minOut` is still enforced post-swap even in OPERATOR_TRUSTED mode.
    function test_GivenOperatorTrusted_StillEnforcesMinOut() external whenAmountNotZero {
        _allowPairTrusted(users.vault, address(usdc), address(usdt));
        mockOracle.setUnknown(address(usdc), address(usdt), true);

        uint256 amountIn = defaults.SWAP_AMOUNT_IN();
        uint256 actualOut = amountIn / 2;
        _armAggregator(actualOut, address(swapAdapter));

        vm.prank(users.vault);
        vm.expectRevert(abi.encodeWithSelector(IYoSwapAdapter.InsufficientOutput.selector, actualOut, amountIn));
        swapAdapter.swap(address(usdc), address(usdt), amountIn, amountIn, type(uint256).max, _execCalldata(amountIn));
    }
}
