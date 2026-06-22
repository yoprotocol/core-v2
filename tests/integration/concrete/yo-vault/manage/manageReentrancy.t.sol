// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { YoSwapAdapter } from "src/adapters/swap/YoSwapAdapter.sol";
import { IYoSwapAdapter } from "src/interfaces/IYoSwapAdapter.sol";
import { IYoSwapOracle } from "src/interfaces/IYoSwapOracle.sol";
import { IYoSwapPairRegistry } from "src/interfaces/IYoSwapPairRegistry.sol";
import { YoVault } from "src/YoVault.sol";
import { YoVaultBase_Test } from "./../YoVaultBase.t.sol";

/// @notice Regression coverage for Cantina issue #4 — cross-adapter reentrancy double-counting a
///         swap's `tokenOut` delta. The `nonReentrant` guard on `YoVault.manage` now rejects any
///         re-entry into `manage` while an outer managed call is still executing, which is the only
///         vector by which a second adapter could be driven mid-swap.
contract ManageReentrancyIntegrationConcreteTest is YoVaultBase_Test {
    uint256 internal constant AMOUNT_IN = 1000e6;
    uint256 internal constant FAIR_OUT = 1000e6;

    ReentrantSwapAggregator internal aggregator;
    YoSwapAdapter internal adapter1;
    YoSwapAdapter internal adapter2;
    ReentrantManageOperator internal operator;

    function setUp() public override {
        super.setUp();

        aggregator = new ReentrantSwapAggregator();
        adapter1 = _deployAdapter();
        adapter2 = _deployAdapter();
        operator = new ReentrantManageOperator(YoVault(payable(address(yoVault))), address(aggregator));

        // Allowlist USDC -> USDT for the vault and quote it 1:1.
        _allowPair(address(yoVault), address(usdc), address(usdt));
        mockOracle.setQuote(address(usdc), address(usdt), defaults.ORACLE_QUOTE_1_TO_1());

        // Registry caps + on-chain allowances so each adapter can pull `tokenIn` from the vault.
        _approveAdapter(adapter1);
        _approveAdapter(adapter2);

        // Authorize the attacker contract for `manage` and for `swap` on both adapters.
        _authorize(address(operator), address(yoVault), MANAGE_SINGLE_SELECTOR);
        _authorize(address(operator), address(adapter1), IYoSwapAdapter.swap.selector);
        _authorize(address(operator), address(adapter2), IYoSwapAdapter.swap.selector);

        // Fund the vault for two swaps and the aggregator with output liquidity.
        usdc.mint(address(yoVault), 2 * AMOUNT_IN);
        usdt.mint(address(aggregator), 2 * FAIR_OUT);
    }

    /// @dev The reported attack: adapter1's aggregator callback re-enters `manage` to run adapter2,
    ///      whose honest output would be credited to adapter1's balance-delta check. The guard now
    ///      reverts the nested `manage`, collapsing the whole attack.
    function test_RevertWhen_AManagedCallReentersManageThroughADifferentAdapter() external {
        operator.setReentry(address(adapter2), _swapCalldata(_honestAggCalldata()));

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        operator.attack(address(adapter1), _swapCalldata(_reentrantAggCalldata()));
    }

    /// @dev Same-adapter re-entry was already blocked by the adapter-local guard; with the `manage`
    ///      guard it now trips one frame earlier. Either way the call must revert.
    function test_RevertWhen_AManagedCallReentersManageThroughTheSameAdapter() external {
        operator.setReentry(address(adapter1), _swapCalldata(_honestAggCalldata()));

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        operator.attack(address(adapter1), _swapCalldata(_reentrantAggCalldata()));
    }

    /// @dev The guard must not regress legitimate single-hop swaps routed through `manage`.
    function test_WhenASingleManagedSwapDoesNotReenter() external {
        _authorize(users.operator, address(adapter1), IYoSwapAdapter.swap.selector);

        uint256 vaultUsdcBefore = usdc.balanceOf(address(yoVault));
        uint256 vaultUsdtBefore = usdt.balanceOf(address(yoVault));

        vm.prank(users.operator);
        bytes memory ret = yoVault.manage(address(adapter1), _swapCalldata(_honestAggCalldata()), 0);

        assertEq(abi.decode(ret, (uint256)), FAIR_OUT, "amountOut return");
        assertEq(usdc.balanceOf(address(yoVault)), vaultUsdcBefore - AMOUNT_IN, "vault USDC out");
        assertEq(usdt.balanceOf(address(yoVault)), vaultUsdtBefore + FAIR_OUT, "vault USDT in");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _deployAdapter() internal returns (YoSwapAdapter) {
        return new YoSwapAdapter({
            _aggregator: address(aggregator),
            _oracle: IYoSwapOracle(address(mockOracle)),
            _registry: IYoSwapPairRegistry(address(pairRegistry)),
            _maxSlippageBps: defaults.MAX_SLIPPAGE_BPS(),
            _yoRegistry: yoRegistry
        });
    }

    function _approveAdapter(YoSwapAdapter adapter) internal {
        _setApproval(address(yoVault), address(usdc), address(adapter), AMOUNT_IN);
        vm.prank(users.owner);
        yoVault.approveToken(address(usdc), address(adapter), AMOUNT_IN);
    }

    function _swapCalldata(bytes memory aggregatorCalldata) internal view returns (bytes memory) {
        return abi.encodeCall(
            IYoSwapAdapter.swap,
            (address(usdc), address(usdt), AMOUNT_IN, FAIR_OUT, type(uint256).max, aggregatorCalldata)
        );
    }

    function _honestAggCalldata() internal view returns (bytes memory) {
        return
            abi.encodeCall(ReentrantSwapAggregator.executeHonest, (address(usdc), address(usdt), AMOUNT_IN, FAIR_OUT));
    }

    function _reentrantAggCalldata() internal view returns (bytes memory) {
        return abi.encodeCall(ReentrantSwapAggregator.executeReentrant, (address(usdc), AMOUNT_IN, address(operator)));
    }
}

/// @notice Aggregator stand-in whose route can call back into an operator mid-swap, modelling a
///         DEX/aggregator with a post-swap hook that returns control to `msg.sender`'s context.
contract ReentrantSwapAggregator {
    using SafeERC20 for IERC20;

    /// @dev Honest fill: consume `tokenIn` from the adapter, deliver `tokenOut` back to it.
    function executeHonest(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    /// @dev Malicious route: consume `tokenIn`, then hand control to `executor` before settling.
    function executeReentrant(address tokenIn, uint256 amountIn, address executor) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IReentrantManageExecutor(executor).reenter();
    }
}

interface IReentrantManageExecutor {
    function reenter() external;
}

/// @notice Authorized operator stand-in that initiates a managed swap and re-enters `manage` from
///         inside the aggregator callback.
contract ReentrantManageOperator is IReentrantManageExecutor {
    YoVault internal immutable vault;
    address internal immutable aggregator;

    address internal reenterTarget;
    bytes internal reenterCalldata;

    constructor(YoVault _vault, address _aggregator) {
        vault = _vault;
        aggregator = _aggregator;
    }

    function setReentry(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterCalldata = data;
    }

    function attack(address adapter, bytes calldata swapCalldata) external returns (bytes memory) {
        return vault.manage(adapter, swapCalldata, 0);
    }

    function reenter() external {
        require(msg.sender == aggregator, "only aggregator");
        vault.manage(reenterTarget, reenterCalldata, 0);
    }
}
