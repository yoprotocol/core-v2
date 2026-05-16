// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Id, IMorpho, MarketParams } from "src/interfaces/IMorpho.sol";
import { IStETH } from "src/interfaces/external/IStETH.sol";
import { IWETH9 } from "src/interfaces/external/IWETH9.sol";
import { IWithdrawalQueueERC721 } from "src/interfaces/external/IWithdrawalQueueERC721.sol";
import { IYoSwapOracle } from "src/interfaces/IYoSwapOracle.sol";
import { IYoSwapPairRegistry } from "src/interfaces/IYoSwapPairRegistry.sol";

import { YoApprovalRegistry } from "src/registries/YoApprovalRegistry.sol";
import { YoERC4626VaultRegistry } from "src/registries/YoERC4626VaultRegistry.sol";
import { YoMorphoMarketRegistry } from "src/registries/YoMorphoMarketRegistry.sol";
import { YoSwapPairRegistry } from "src/registries/YoSwapPairRegistry.sol";
import { YoERC4626Adapter } from "src/adapters/erc4626/YoERC4626Adapter.sol";
import { YoIPORAdapter } from "src/adapters/ipor/YoIPORAdapter.sol";
import { YoLidoAdapter } from "src/adapters/lido/YoLidoAdapter.sol";
import { YoMorphoAdapter } from "src/adapters/morpho/YoMorphoAdapter.sol";
import { YoSwapAdapter } from "src/adapters/swap/YoSwapAdapter.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockERC4626 } from "./mocks/MockERC4626.sol";
import { MockIIPORPlasmaVault } from "./mocks/MockIIPORPlasmaVault.sol";
import { MockIIPORWithdrawManager } from "./mocks/MockIIPORWithdrawManager.sol";
import { MockLidoWithdrawalQueue } from "./mocks/MockLidoWithdrawalQueue.sol";
import { MockMorpho } from "./mocks/MockMorpho.sol";
import { MockOneInchRouter } from "./mocks/MockOneInchRouter.sol";
import { MockStETH } from "./mocks/MockStETH.sol";
import { MockSwapOracle } from "./mocks/MockSwapOracle.sol";
import { MockWETH9 } from "./mocks/MockWETH9.sol";
import { MockYoRegistry } from "./mocks/MockYoRegistry.sol";

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
    MockERC4626 internal mockYieldVault;
    MockIIPORPlasmaVault internal mockPlasmaVault;
    MockIIPORWithdrawManager internal mockIPORWithdrawManager;
    MockWETH9 internal mockWETH;
    MockStETH internal mockStETH;
    MockLidoWithdrawalQueue internal mockLidoQueue;

    // Yo contracts under test
    YoApprovalRegistry internal approvalRegistry;
    YoMorphoMarketRegistry internal marketRegistry;
    YoSwapPairRegistry internal pairRegistry;
    YoERC4626VaultRegistry internal yieldVaultRegistry;
    MockYoRegistry internal yoRegistry;
    YoMorphoAdapter internal morphoAdapter;
    YoSwapAdapter internal swapAdapter;
    YoERC4626Adapter internal yieldAdapter;
    YoIPORAdapter internal iporAdapter;
    YoLidoAdapter internal lidoAdapter;

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
        users.alice = payable(makeAddr("Alice"));
        users.bob = payable(makeAddr("Bob"));
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
        mockYieldVault = new MockERC4626(IERC20(address(usdc)), "Mock Yield Vault", "mYV");
        mockIPORWithdrawManager = new MockIIPORWithdrawManager(defaults.IPOR_WITHDRAW_WINDOW());
        mockPlasmaVault = new MockIIPORPlasmaVault(
            IERC20(address(usdc)), "Mock Plasma Vault", "mPV", mockIPORWithdrawManager
        );
        mockWETH = new MockWETH9();
        mockStETH = new MockStETH();
        mockLidoQueue = new MockLidoWithdrawalQueue(IERC20(address(mockStETH)));
        vm.deal(address(mockLidoQueue), 1000 ether); // pre-fund for claim payouts in tests
        vm.label(address(mockMorpho), "MockMorpho");
        vm.label(address(mockAggregator), "MockOneInchRouter");
        vm.label(address(mockOracle), "MockSwapOracle");
        vm.label(address(mockYieldVault), "MockERC4626");
        vm.label(address(mockPlasmaVault), "MockIIPORPlasmaVault");
        vm.label(address(mockIPORWithdrawManager), "MockIIPORWithdrawManager");
        vm.label(address(mockWETH), "MockWETH9");
        vm.label(address(mockStETH), "MockStETH");
        vm.label(address(mockLidoQueue), "MockLidoWithdrawalQueue");

        // MockYoRegistry — drops the IERC4626 contract requirement on `addYoVault` so the EOA
        // stand-in `users.vault` can be marked as a registered vault. The real `YoRegistry` is
        // exercised separately by the BTT + fuzz suites in `tests/integration/concrete/yo-registry`.
        yoRegistry = new MockYoRegistry();
        yoRegistry.setVault(users.vault, true);

        // Deploy Yo contracts as the multisig owner.
        vm.startPrank(users.owner);
        approvalRegistry = new YoApprovalRegistry(users.owner);
        marketRegistry = new YoMorphoMarketRegistry(users.owner);
        pairRegistry = new YoSwapPairRegistry(users.owner);
        yieldVaultRegistry = new YoERC4626VaultRegistry(users.owner);
        morphoAdapter = new YoMorphoAdapter(IMorpho(address(mockMorpho)), marketRegistry, yoRegistry);
        swapAdapter = new YoSwapAdapter({
            _aggregator: address(mockAggregator),
            _oracle: IYoSwapOracle(address(mockOracle)),
            _registry: IYoSwapPairRegistry(address(pairRegistry)),
            _maxSlippageBps: defaults.MAX_SLIPPAGE_BPS(),
            _yoRegistry: yoRegistry
        });
        yieldAdapter = new YoERC4626Adapter(yieldVaultRegistry, yoRegistry);
        iporAdapter = new YoIPORAdapter(yieldVaultRegistry, yoRegistry);
        lidoAdapter = new YoLidoAdapter({
            _stETH: IStETH(address(mockStETH)),
            _queue: IWithdrawalQueueERC721(address(mockLidoQueue)),
            _weth: IWETH9(address(mockWETH)),
            _referral: address(0),
            _yoRegistry: yoRegistry
        });
        vm.stopPrank();
        vm.label(address(approvalRegistry), "YoApprovalRegistry");
        vm.label(address(marketRegistry), "YoMorphoMarketRegistry");
        vm.label(address(pairRegistry), "YoSwapPairRegistry");
        vm.label(address(yieldVaultRegistry), "YoERC4626VaultRegistry");
        vm.label(address(yoRegistry), "YoRegistry");
        vm.label(address(morphoAdapter), "YoMorphoAdapter");
        vm.label(address(swapAdapter), "YoSwapAdapter");
        vm.label(address(yieldAdapter), "YoERC4626Adapter");
        vm.label(address(iporAdapter), "YoIPORAdapter");
        vm.label(address(lidoAdapter), "YoLidoAdapter");

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

    function _allowYieldVault(address vault, IERC4626 yieldVault) internal {
        vm.prank(users.owner);
        yieldVaultRegistry.setAllowed(vault, address(yieldVault), true);
    }
}
