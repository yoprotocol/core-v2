// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoSwapAdapter } from "src/adapters/swap/YoSwapAdapter.sol";
import { IYoSwapOracle } from "src/interfaces/IYoSwapOracle.sol";
import { IYoSwapPairRegistry } from "src/interfaces/IYoSwapPairRegistry.sol";

import { Fork_Test } from "../Fork_Test.t.sol";

/// @dev Uniswap V3 SwapRouter02 calldata.
interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice End-to-end: real YoVault → YoSwapAdapter → real Uniswap V3 SwapRouter on Base.
///         Swaps real USDC for real WETH and back. The adapter uses OPERATOR_TRUSTED mode (no
///         oracle floor) — the on-chain price oracle is exercised separately in unit tests.
contract SwapForkTest is Fork_Test {
    uint256 internal constant BASE_BLOCK = 0;

    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 internal constant WETH = IERC20(0x4200000000000000000000000000000000000006);
    address internal constant UNIV3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // SwapRouter02
    uint24 internal constant POOL_FEE_005 = 500; // 0.05% USDC/WETH tier

    uint256 internal constant DEPOSIT = 50_000e6;
    uint256 internal constant MAX_SLIPPAGE_BPS = 100; // 1% (unused in OPERATOR_TRUSTED)

    YoSwapAdapter internal adapter;

    function setUp() public {
        _maybeSkip(_forkIfAvailable("base", BASE_BLOCK));

        _deployStack(USDC, "Yo USDC Vault", "yoUSDC");

        // We use OPERATOR_TRUSTED → the oracle param is unused; pass any non-zero address.
        adapter = new YoSwapAdapter({
            _aggregator: UNIV3_ROUTER,
            _oracle: IYoSwapOracle(address(0xCAFE)),
            _registry: IYoSwapPairRegistry(address(pairRegistry)),
            _maxSlippageBps: MAX_SLIPPAGE_BPS,
            _yoRegistry: yoRegistry
        });
        vm.label(address(adapter), "YoSwapAdapter");

        // Both directions allowlisted in OPERATOR_TRUSTED mode.
        vm.startPrank(users.owner);
        pairRegistry.setMode(
            address(yoVault), address(USDC), address(WETH), IYoSwapPairRegistry.PairMode.OPERATOR_TRUSTED
        );
        pairRegistry.setMode(
            address(yoVault), address(WETH), address(USDC), IYoSwapPairRegistry.PairMode.OPERATOR_TRUSTED
        );
        vm.stopPrank();

        deal(address(USDC), address(yoVault), DEPOSIT);

        _vaultApprove(USDC, address(adapter), DEPOSIT);
    }

    function test_Fork_Swap_USDCtoWETH() external {
        uint256 wethBefore = WETH.balanceOf(address(yoVault));

        bytes memory routerCall = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: address(USDC),
                tokenOut: address(WETH),
                fee: POOL_FEE_005,
                // Recipient = adapter; the adapter sweeps tokenOut to the vault after the call.
                recipient: address(adapter),
                amountIn: DEPOSIT,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // minOut = 1 wei (just enforces "got something"); operator's slippage policy lives off-chain.
        bytes memory swapCall = abi.encodeCall(
            YoSwapAdapter.swap, (address(USDC), address(WETH), DEPOSIT, 1, type(uint256).max, routerCall)
        );
        _opManage(address(adapter), swapCall);

        assertGt(WETH.balanceOf(address(yoVault)) - wethBefore, 0, "vault received WETH");
        assertEq(USDC.balanceOf(address(yoVault)), 0, "USDC consumed");

        // Adapter ends clean.
        assertEq(USDC.balanceOf(address(adapter)), 0, "adapter USDC zero");
        assertEq(WETH.balanceOf(address(adapter)), 0, "adapter WETH zero");
        assertEq(USDC.allowance(address(adapter), UNIV3_ROUTER), 0, "no leftover allowance");
    }

    function test_Fork_Swap_RoundTripUSDCtoWETHandBack() external {
        uint256 usdcBefore = USDC.balanceOf(address(yoVault));

        // Leg 1: USDC → WETH
        bytes memory leg1Router = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: address(USDC),
                tokenOut: address(WETH),
                fee: POOL_FEE_005,
                recipient: address(adapter),
                amountIn: DEPOSIT,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        bytes memory leg1Swap = abi.encodeCall(
            YoSwapAdapter.swap, (address(USDC), address(WETH), DEPOSIT, 1, type(uint256).max, leg1Router)
        );
        _opManage(address(adapter), leg1Swap);

        uint256 wethAfter = WETH.balanceOf(address(yoVault));
        assertGt(wethAfter, 0, "got WETH from leg 1");

        // Approve the reverse leg.
        _vaultApprove(WETH, address(adapter), wethAfter);

        // Leg 2: WETH → USDC, all of it.
        bytes memory leg2Router = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: address(WETH),
                tokenOut: address(USDC),
                fee: POOL_FEE_005,
                recipient: address(adapter),
                amountIn: wethAfter,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        bytes memory leg2Swap = abi.encodeCall(
            YoSwapAdapter.swap, (address(WETH), address(USDC), wethAfter, 1, type(uint256).max, leg2Router)
        );
        _opManage(address(adapter), leg2Swap);

        // After 2× 5bps fees + AMM slippage, vault USDC ≈ (1 - 2·5bps) · DEPOSIT.
        uint256 usdcAfter = USDC.balanceOf(address(yoVault));
        // Loose bound: at most 1% loss on a single-block round trip with deep liquidity.
        assertGt(usdcAfter, (usdcBefore * 99) / 100, unicode"≤ 1% round-trip loss");
        assertLe(usdcAfter, usdcBefore, "no free money");
    }
}
