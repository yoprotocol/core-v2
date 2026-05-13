// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Base_Test } from "../Base.t.sol";

import { MorphoAdapterHandler } from "./handlers/MorphoAdapterHandler.sol";
import { SwapAdapterHandler } from "./handlers/SwapAdapterHandler.sol";
import { Store } from "./stores/Store.sol";

/// @notice Protocol-wide invariants for the operator-safety architecture.
/// @dev    `StdInvariant` is inherited transitively via `forge-std/Test`.
contract Invariant_Test is Base_Test {
    Store internal store;
    MorphoAdapterHandler internal morphoHandler;
    SwapAdapterHandler internal swapHandler;

    function setUp() public virtual override {
        Base_Test.setUp();

        // Wire registries / approvals exactly as the integration suite does.
        _setupMarket(defaults.MARKET_A(), address(usdc));
        _allowMarket(users.vault, defaults.MARKET_A());
        mockOracle.setQuote(address(usdc), address(usdt), defaults.ORACLE_QUOTE_1_TO_1());
        _allowPair(users.vault, address(usdc), address(usdt));

        // Vault pre-approves both adapters.
        vm.startPrank(users.vault);
        usdc.approve(address(morphoAdapter), type(uint256).max);
        usdc.approve(address(swapAdapter), type(uint256).max);
        vm.stopPrank();

        // Authorize the Morpho adapter to act on behalf of the vault on the mock.
        vm.prank(users.vault);
        mockMorpho.setAuthorization(address(morphoAdapter), true);

        // Deploy store + handlers.
        store = new Store();
        vm.label(address(store), "Store");

        morphoHandler = new MorphoAdapterHandler({
            _adapter: morphoAdapter,
            _vault: users.vault,
            _token: usdc,
            _market: defaults.MARKET_A(),
            _store: store
        });

        swapHandler = new SwapAdapterHandler({
            _adapter: swapAdapter,
            _vault: users.vault,
            _in: usdc,
            _out: usdt,
            _aggregator: mockAggregator,
            _oracle: mockOracle,
            _store: store
        });

        // Pre-fund vault to give handlers room to swap.
        usdc.mint(users.vault, 1_000_000e6);
        usdt.mint(address(mockAggregator), 1_000_000e6);

        // Target handlers; exclude infrastructure as senders.
        targetContract(address(morphoHandler));
        targetContract(address(swapHandler));
        excludeSender(address(store));
        excludeSender(address(mockMorpho));
        excludeSender(address(mockAggregator));
        excludeSender(address(mockOracle));
        excludeSender(address(morphoAdapter));
        excludeSender(address(swapAdapter));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ADAPTER CUSTODY
    //////////////////////////////////////////////////////////////////////////*/

    function invariant_MorphoAdapter_HoldsZeroBalance() external view {
        assertEq(usdc.balanceOf(address(morphoAdapter)), 0, "morpho adapter holds USDC");
    }

    function invariant_SwapAdapter_HoldsZeroBalance() external view {
        assertEq(usdc.balanceOf(address(swapAdapter)), 0, "swap adapter holds USDC");
        assertEq(usdt.balanceOf(address(swapAdapter)), 0, "swap adapter holds USDT");
    }

    function invariant_MorphoAdapter_ZeroAllowance() external view {
        assertEq(
            usdc.allowance(address(morphoAdapter), address(mockMorpho)),
            0,
            "morpho adapter has standing Morpho allowance"
        );
    }

    function invariant_SwapAdapter_ZeroAllowance() external view {
        assertEq(
            usdc.allowance(address(swapAdapter), address(mockAggregator)),
            0,
            "swap adapter has standing aggregator allowance"
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                 PROTOCOL SAFETY
    //////////////////////////////////////////////////////////////////////////*/

    function invariant_AuthorizationStillIntact() external view {
        assertTrue(
            mockMorpho.isAuthorized(users.vault, address(morphoAdapter)),
            "adapter authorization revoked unexpectedly"
        );
    }
}
