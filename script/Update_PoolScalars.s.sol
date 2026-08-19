// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { IYoPoolRegistry, PoolId } from "../src/interfaces/IYoPoolRegistry.sol";
import { YoPoolRegistry } from "../src/registries/YoPoolRegistry.sol";

import { BaseScript } from "./Base.s.sol";
import { ChainId } from "./ChainId.sol";

/// @notice Companion to {Seed_PoolRegistry}: applies the scalar updates from the yo-backend
///         `db.Pool.updateOne` batch of 2026-08-04 (cost fractions, risk scores, exit latencies
///         for the carried holdings and Lido wstETH). Each update is a read-modify-write: the
///         stored config is fetched and only the five scalar fields are patched, so identity,
///         venue, and adapter fields cannot drift. Reverts if a target pool is not seeded yet —
///         run {Seed_PoolRegistry} first.
///
///         Required env vars:
///           - POOL_REGISTRY:      the {YoPoolRegistry} instance on Base.
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}); must be the registry
///                                 owner.
contract Update_PoolScalars is BaseScript {
    error RegistryOwnerMismatch(address owner, address broadcaster);
    error PoolNotSeeded(address vault, string offchainId);

    address internal constant YO_USD = 0x0000000f2eB9f69274678c76222B35eEc7588a65;
    address internal constant YO_ETH = 0x3A43AEC53490CB9Fa922847385D82fe25d0E9De7;
    address internal constant YO_USD_EDGE = 0x5DD8BFa6C5C68D05d25EF6143E05C11E26c4cDB7;

    YoPoolRegistry internal registry;

    function run() public broadcast {
        if (chainId != ChainId.BASE) {
            revert ChainNotSupported("Update_PoolScalars", chainId);
        }

        registry = YoPoolRegistry(vm.envAddress("POOL_REGISTRY"));
        if (registry.owner() != broadcaster) {
            revert RegistryOwnerMismatch(registry.owner(), broadcaster);
        }

        // USDT: deepest stable pair there is; ~1 bp each way against USDC, synchronous, no
        // rate-vs-size response.
        _update({
            vault: YO_USD,
            offchainId: "ethereum:holding:usdt",
            riskScore: 99,
            entrySlippageWad: 0.0001e18,
            exitCostWad: 0.0001e18,
            exitLatencySeconds: 0,
            elasticityWad: 0
        });

        // Lido wstETH: invest/divest run through EnsoRouter market swaps (not the withdrawal
        // queue), so latency is 0 and cost is the WETH<->wstETH market round trip, ~5 bps with
        // routing included.
        _update({
            vault: YO_ETH,
            offchainId: "ethereum:lido:wsteth",
            riskScore: 99,
            entrySlippageWad: 0.0005e18,
            exitCostWad: 0.0005e18,
            exitLatencySeconds: 0,
            elasticityWad: 0
        });

        // fxUSD: par-held stable with thinner venues than the majors; ~10 bps for the
        // fxUSD<->USDC swap.
        _update({
            vault: YO_USD_EDGE,
            offchainId: "ethereum:holding:fxusd",
            riskScore: 95,
            entrySlippageWad: 0.001e18,
            exitCostWad: 0.001e18,
            exitLatencySeconds: 0,
            elasticityWad: 0
        });

        // fxSAVE: mints and redeems at NAV in fxUSD, so both figures are the swap-inclusive
        // fxUSD<->USDC leg (~10 bps). Latency 86400 REVIEW: divest is request-mode via the
        // redeemer, and one day is a placeholder for f(x)'s actual claim window — confirm
        // against the protocol before live mode.
        _update({
            vault: YO_USD_EDGE,
            offchainId: "ethereum:fxsave:fxsave",
            riskScore: 95,
            entrySlippageWad: 0.001e18,
            exitCostWad: 0.001e18,
            exitLatencySeconds: 86_400,
            elasticityWad: 0
        });

        // USDG: Paxos-issued, near-par against USDC with decent depth; ~2 bps each way,
        // synchronous.
        _update({
            vault: YO_USD_EDGE,
            offchainId: "ethereum:holding:usdg",
            riskScore: 98,
            entrySlippageWad: 0.0002e18,
            exitCostWad: 0.0002e18,
            exitLatencySeconds: 0,
            elasticityWad: 0
        });

        console2.log("=== Pool scalars updated: 5 pools ===");
    }

    /// @dev Patches only the scalar fields of an already-seeded pool and writes the config back.
    function _update(
        address vault,
        string memory offchainId,
        uint8 riskScore,
        uint64 entrySlippageWad,
        uint64 exitCostWad,
        uint32 exitLatencySeconds,
        uint64 elasticityWad
    )
        private
    {
        PoolId id = registry.computePoolId(offchainId);
        IYoPoolRegistry.PoolConfig memory config = registry.configOf(vault, id);
        if (config.status == IYoPoolRegistry.PoolStatus.NONE) {
            revert PoolNotSeeded(vault, offchainId);
        }

        config.riskScore = riskScore;
        config.entrySlippageWad = entrySlippageWad;
        config.exitCostWad = exitCostWad;
        config.exitLatencySeconds = exitLatencySeconds;
        config.elasticityWad = elasticityWad;
        registry.setPool(vault, offchainId, config);

        console2.log("updated:", offchainId);
    }
}
