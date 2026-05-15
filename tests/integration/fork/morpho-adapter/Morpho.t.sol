// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Id, IMorpho, MarketParams, Position } from "src/interfaces/IMorpho.sol";
import { YoMorphoAdapter } from "src/adapters/morpho/YoMorphoAdapter.sol";
import { IYoMorphoMarketRegistry } from "src/interfaces/IYoMorphoMarketRegistry.sol";

import { Fork_Test } from "../Fork_Test.t.sol";

/// @dev Extended interface for permissionless market creation on the fork. Not in the production
///      IMorpho because adapters never call it.
interface IMorphoExtended is IMorpho {
    function createMarket(MarketParams memory) external;
}

/// @notice End-to-end: real YoVault → real Morpho Blue on Base mainnet. Deposit flow asserts
///         that supply moves USDC into a fresh market and lands shares on the vault; withdraw
///         flow asserts that `withdrawAll` closes the position and returns USDC. Round-trip is
///         lossless (within 1 wei of Morpho's per-share rounding).
contract MorphoFork_Test is Fork_Test {
    // ── Pinned Base mainnet block
    // ────────────────────────────────────────────
    uint256 internal constant BASE_BLOCK = 0;

    // ── Real Base addresses
    // ──────────────────────────────────────────────────
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    IMorphoExtended internal constant MORPHO = IMorphoExtended(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    /// @dev Adaptive Curve IRM on Base. Enabled at Morpho deploy time; never removed.
    address internal constant ADAPTIVE_CURVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    /// @dev Standard 86% LLTV (enabled).
    uint256 internal constant LLTV = 0.86e18;

    uint256 internal constant DEPOSIT = 100_000e6;

    YoMorphoAdapter internal adapter;
    Id internal marketId;
    MarketParams internal market;

    function setUp() public {
        _maybeSkip(_forkIfAvailable("BASE_RPC_URL", BASE_BLOCK), "BASE_RPC_URL");

        _deployStack(USDC, "Yo USDC Vault", "yoUSDC");

        // Adapter under test, wired to real Morpho + our market registry.
        adapter = new YoMorphoAdapter(
            IMorpho(address(MORPHO)), IYoMorphoMarketRegistry(address(marketRegistry)), yoRegistry
        );
        vm.label(address(adapter), "YoMorphoAdapter");

        // Deploy a fresh market on the fork. Permissionless: needs only an enabled IRM + LLTV.
        // The oracle slot is NOT validated by createMarket, so we leave it as a dummy.
        market = MarketParams({
            loanToken: address(USDC),
            collateralToken: WETH,
            oracle: address(0xCAFE),
            irm: ADAPTIVE_CURVE_IRM,
            lltv: LLTV
        });
        MORPHO.createMarket(market);
        marketId = Id.wrap(keccak256(abi.encode(market)));

        // Allowlist the market for the vault.
        vm.prank(users.owner);
        marketRegistry.setAllowed(address(yoVault), marketId, true);

        // Fund the vault with USDC.
        deal(address(USDC), address(yoVault), DEPOSIT);

        // Approve the adapter to pull USDC.
        _vaultApprove(USDC, address(adapter), DEPOSIT);

        // One-time Morpho authorization: vault authorizes the adapter so it can withdraw on the
        // vault's behalf. The spec calls this out as a per-vault setup step in the runbook.
        bytes memory authCall = abi.encodeCall(IMorpho.setAuthorization, (address(adapter), true));
        _opManage(address(MORPHO), authCall);
    }

    function test_Fork_Morpho_DepositWithdrawRoundTrip() external {
        uint256 vaultBefore = USDC.balanceOf(address(yoVault));

        // Deposit (supply).
        bytes memory supplyCall = abi.encodeCall(YoMorphoAdapter.supply, (marketId, DEPOSIT));
        _opManage(address(adapter), supplyCall);

        // Vault USDC drained; Morpho position holds the supply shares.
        assertEq(USDC.balanceOf(address(yoVault)), vaultBefore - DEPOSIT, "vault drained");
        Position memory pos = MORPHO.position(marketId, address(yoVault));
        assertGt(pos.supplyShares, 0, "Morpho recorded supply");

        // Withdraw (withdrawAll).
        bytes memory withdrawCall = abi.encodeCall(YoMorphoAdapter.withdrawAll, (marketId));
        _opManage(address(adapter), withdrawCall);

        // Position closed, vault USDC restored within rounding.
        Position memory after_ = MORPHO.position(marketId, address(yoVault));
        assertEq(after_.supplyShares, 0, "position closed");

        uint256 vaultAfter = USDC.balanceOf(address(yoVault));
        // Morpho compounds shares; with no other suppliers and no time passing on a single-tx
        // round-trip, recovery is within 1 wei of the original deposit.
        uint256 diff = vaultBefore > vaultAfter ? vaultBefore - vaultAfter : vaultAfter - vaultBefore;
        assertLe(diff, 1, "lossless within 1 wei");
    }

    function test_Fork_Morpho_PartialWithdraw() external {
        bytes memory supplyCall = abi.encodeCall(YoMorphoAdapter.supply, (marketId, DEPOSIT));
        _opManage(address(adapter), supplyCall);

        uint256 part = DEPOSIT / 4;
        bytes memory withdrawCall = abi.encodeCall(YoMorphoAdapter.withdraw, (marketId, part));
        _opManage(address(adapter), withdrawCall);

        // Vault got back exactly `part`, position still has 75%-ish of shares.
        assertEq(USDC.balanceOf(address(yoVault)), part, "vault got part");
        Position memory pos = MORPHO.position(marketId, address(yoVault));
        assertGt(pos.supplyShares, 0, "position not closed");
    }
}
