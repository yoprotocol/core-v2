// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Base_Test } from "../Base.t.sol";

/// @notice Common base for integration tests (concrete + fuzz).
abstract contract Integration_Test is Base_Test {
    function setUp() public virtual override {
        Base_Test.setUp();

        // Default market wired so concrete tests can immediately exercise supply/withdraw.
        // MARKET_B is intentionally NOT registered in MockMorpho — tests that need a
        // "registered-but-not-allowlisted" market are blocked by the registry check first.
        _setupMarket(defaults.MARKET_A(), address(usdc));

        // Default approvals & allowlists for the standard vault stand-in.
        _allowMarket(users.vault, defaults.MARKET_A());

        // Default oracle quote for USDC/USDT pair (1:1).
        mockOracle.setQuote(address(usdc), address(usdt), defaults.ORACLE_QUOTE_1_TO_1());
        _allowPair(users.vault, address(usdc), address(usdt));

        // Pre-mint balances for the vault stand-in.
        usdc.mint(users.vault, 1_000_000e6);
        usdt.mint(users.vault, 1_000_000e6);

        // Vault pre-approves the Morpho adapter and the swap adapter so they can pull on supply/swap.
        // Vault also authorizes the Morpho adapter to act on its behalf (needed for withdraw paths).
        vm.startPrank(users.vault);
        usdc.approve(address(morphoAdapter), type(uint256).max);
        usdc.approve(address(swapAdapter), type(uint256).max);
        mockMorpho.setAuthorization(address(morphoAdapter), true);
        vm.stopPrank();

        // Pre-fund the aggregator router so it can deliver `tokenOut` on swap.
        usdt.mint(address(mockAggregator), 1_000_000e6);
    }
}
