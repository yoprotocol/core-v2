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
        link.mint(users.vault, 1_000_000e18);

        // Default bridge routes for the standard vault stand-in (one per bridge adapter).
        _allowRoute(
            users.vault,
            address(acrossAdapter),
            address(usdc),
            defaults.ACROSS_DEST_CHAIN_ID(),
            defaults.BRIDGE_RECIPIENT()
        );
        _allowRoute(
            users.vault, address(cctpAdapter), address(usdc), defaults.CCTP_DEST_DOMAIN(), defaults.BRIDGE_RECIPIENT()
        );
        _allowRoute(
            users.vault, address(ccipAdapter), address(usdc), defaults.CCIP_DEST_SELECTOR(), defaults.BRIDGE_RECIPIENT()
        );
        _allowRoute(
            users.vault,
            address(mayanAdapter),
            address(usdc),
            defaults.MAYAN_DEST_WORMHOLE_CHAIN(),
            defaults.BRIDGE_RECIPIENT()
        );

        // Default yield-vault allowlist + USDC approvals. The IPOR PlasmaVault reuses the shared
        // ERC-4626 vault registry.
        _allowYieldVault(users.vault, mockYieldVault);
        _allowYieldVault(users.vault, mockPlasmaVault);

        // Vault pre-approves all adapters so they can pull tokens / shares as needed.
        vm.startPrank(users.vault);
        usdc.approve(address(morphoAdapter), type(uint256).max);
        usdc.approve(address(swapAdapter), type(uint256).max);
        usdc.approve(address(yieldAdapter), type(uint256).max);
        usdc.approve(address(iporAdapter), type(uint256).max);
        // Share approval for withdraw paths: vault authorizes adapter on the yield vault's shares.
        mockYieldVault.approve(address(yieldAdapter), type(uint256).max);
        // IPOR claim path: vault authorizes the IPOR adapter on the PlasmaVault's shares.
        mockPlasmaVault.approve(address(iporAdapter), type(uint256).max);
        // Morpho authorization for the Morpho adapter (different mechanism: setAuthorization).
        mockMorpho.setAuthorization(address(morphoAdapter), true);
        // Bridge adapters: vault approves USDC (all three) and LINK (CCIP fee path).
        usdc.approve(address(acrossAdapter), type(uint256).max);
        usdc.approve(address(cctpAdapter), type(uint256).max);
        usdc.approve(address(ccipAdapter), type(uint256).max);
        usdc.approve(address(mayanAdapter), type(uint256).max);
        link.approve(address(ccipAdapter), type(uint256).max);
        // Lido adapter: vault approves WETH (stake), stETH (unstake request), and the withdrawal
        // queue NFT (claim).
        mockWETH.approve(address(lidoAdapter), type(uint256).max);
        mockStETH.approve(address(lidoAdapter), type(uint256).max);
        mockLidoQueue.setApprovalForAll(address(lidoAdapter), true);
        vm.stopPrank();

        // Pre-fund the aggregator router so it can deliver `tokenOut` on swap.
        usdt.mint(address(mockAggregator), 1_000_000e6);
    }
}
