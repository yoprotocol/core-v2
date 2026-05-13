// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/src/Test.sol";

import { Id, IMorpho, MarketParams } from "src/interfaces/IMorpho.sol";
import { IYoApprovalRegistry } from "src/interfaces/IYoApprovalRegistry.sol";
import { IYoMorphoAdapter } from "src/interfaces/IYoMorphoAdapter.sol";
import { IYoMorphoMarketRegistry } from "src/interfaces/IYoMorphoMarketRegistry.sol";
import { IYoSwapOracle } from "src/interfaces/IYoSwapOracle.sol";
import { IYoSwapPairRegistry } from "src/interfaces/IYoSwapPairRegistry.sol";

import { YoApprovalRegistry } from "src/registries/YoApprovalRegistry.sol";
import { YoMorphoMarketRegistry } from "src/registries/YoMorphoMarketRegistry.sol";
import { YoSwapPairRegistry } from "src/registries/YoSwapPairRegistry.sol";
import { YoMorphoAdapter } from "src/adapters/morpho/YoMorphoAdapter.sol";
import { YoSwapAdapter } from "src/adapters/swap/YoSwapAdapter.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockMorpho } from "./mocks/MockMorpho.sol";
import { MockOneInchRouter } from "./mocks/MockOneInchRouter.sol";
import { MockSwapOracle } from "./mocks/MockSwapOracle.sol";

import { Assertions } from "./utils/Assertions.sol";
import { Defaults } from "./utils/Defaults.sol";
import { Modifiers } from "./utils/Modifiers.sol";
import { Users } from "./utils/Types.sol";

/// @notice Top-level base for the v3 operator-safety test suite.
abstract contract Base_Test is Assertions, Modifiers {
    /*//////////////////////////////////////////////////////////////////////////
                                     VARIABLES
    //////////////////////////////////////////////////////////////////////////*/

    Users internal users;
    Defaults internal defaults;

    /*//////////////////////////////////////////////////////////////////////////
                                  TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    // Tokens
    MockERC20 internal usdc;
    MockERC20 internal usdt;
    MockERC20 internal weth;

    // Mocks of external protocols
    MockMorpho internal mockMorpho;
    MockOneInchRouter internal mockAggregator;
    MockSwapOracle internal mockOracle;

    // Yo contracts under test
    YoApprovalRegistry internal approvalRegistry;
    YoMorphoMarketRegistry internal marketRegistry;
    YoSwapPairRegistry internal pairRegistry;
    YoMorphoAdapter internal morphoAdapter;
    YoSwapAdapter internal swapAdapter;

    /*//////////////////////////////////////////////////////////////////////////
                                  SET-UP FUNCTION
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        defaults = new Defaults();

        // Create users.
        users.owner = payable(makeAddr("Owner"));
        users.operator = payable(makeAddr("Operator"));
        users.guardian = payable(makeAddr("Guardian"));
        users.vault = payable(makeAddr("Vault"));
        users.eve = payable(makeAddr("Eve"));
        defaults.setUsers(users);
        setUsersForModifiers(users);

        // Deploy tokens.
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        vm.label(address(usdc), "USDC");
        vm.label(address(usdt), "USDT");
        vm.label(address(weth), "WETH");

        // Deploy protocol mocks.
        mockMorpho = new MockMorpho();
        mockAggregator = new MockOneInchRouter();
        mockOracle = new MockSwapOracle();
        vm.label(address(mockMorpho), "MockMorpho");
        vm.label(address(mockAggregator), "MockOneInchRouter");
        vm.label(address(mockOracle), "MockSwapOracle");

        // Deploy Yo contracts as the multisig owner.
        vm.startPrank(users.owner);
        approvalRegistry = new YoApprovalRegistry(users.owner);
        marketRegistry = new YoMorphoMarketRegistry(users.owner);
        pairRegistry = new YoSwapPairRegistry(users.owner);
        morphoAdapter = new YoMorphoAdapter(IMorpho(address(mockMorpho)), marketRegistry);
        swapAdapter = new YoSwapAdapter({
            _aggregator: address(mockAggregator),
            _oracle: IYoSwapOracle(address(mockOracle)),
            _registry: IYoSwapPairRegistry(address(pairRegistry)),
            _maxSlippageBps: defaults.MAX_SLIPPAGE_BPS()
        });
        vm.stopPrank();
        vm.label(address(approvalRegistry), "YoApprovalRegistry");
        vm.label(address(marketRegistry), "YoMorphoMarketRegistry");
        vm.label(address(pairRegistry), "YoSwapPairRegistry");
        vm.label(address(morphoAdapter), "YoMorphoAdapter");
        vm.label(address(swapAdapter), "YoSwapAdapter");

        // Warp to a deterministic timestamp.
        vm.warp(defaults.FEB_1_2025());
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _setupMarket(Id id, address loanToken) internal {
        MarketParams memory p = MarketParams({
            loanToken: loanToken,
            collateralToken: address(0xC0),
            oracle: address(0x0),
            irm: address(0x0),
            lltv: 0
        });
        mockMorpho.setMarketParams(id, p);
    }

    function _allowMarket(address vault, Id id) internal {
        vm.prank(users.owner);
        marketRegistry.setAllowed(vault, id, true);
    }

    function _allowPair(address vault, address tokenIn, address tokenOut) internal {
        vm.prank(users.owner);
        pairRegistry.setMode(vault, tokenIn, tokenOut, IYoSwapPairRegistry.PairMode.ORACLE_CHECKED);
    }

    function _allowPairTrusted(address vault, address tokenIn, address tokenOut) internal {
        vm.prank(users.owner);
        pairRegistry.setMode(vault, tokenIn, tokenOut, IYoSwapPairRegistry.PairMode.OPERATOR_TRUSTED);
    }

    function _setApproval(address vault, address token, address spender, uint256 max) internal {
        vm.prank(users.owner);
        approvalRegistry.setApproval(vault, token, spender, max);
    }
}
