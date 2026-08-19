// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoPoolRegistry, PoolId } from "src/interfaces/IYoPoolRegistry.sol";

import { Integration_Test } from "../../Integration.t.sol";

contract SetPool_PoolRegistry_Integration_Fuzz_Test is Integration_Test {
    function test_RevertWhen_RenounceOwnership() external {
        vm.prank(users.owner);
        vm.expectRevert(IYoPoolRegistry.RenounceDisabled.selector);
        poolRegistry.renounceOwnership();
    }

    /// @dev Fuzzed inputs packed in a struct: a 12-argument flat signature blows the stack under
    ///      the legacy (non-IR) pipeline. The struct deliberately mirrors `PoolConfig` WITHOUT the
    ///      `status` enum — Foundry generates raw out-of-range enum values inside fuzzed structs,
    ///      which revert at ABI decode before the test body can clamp them.
    struct RoundTripInputs {
        address vault;
        address adapter;
        bytes32 venueKey;
        bytes32 metadataHash;
        uint8 venueKind;
        bool idleOnly;
        uint8 riskScore;
        uint32 exitLatencySeconds;
        uint64 elasticityWad;
        uint64 entrySlippageWad;
        uint64 exitCostWad;
        uint64 chainId;
    }

    function testFuzz_SetPool_RoundTrips(RoundTripInputs memory inputs) external {
        vm.assume(inputs.vault != address(0) && inputs.adapter != address(0));
        address vault = inputs.vault;
        IYoPoolRegistry.PoolConfig memory config = IYoPoolRegistry.PoolConfig({
            status: IYoPoolRegistry.PoolStatus.ACTIVE,
            // Any non-zero ordinal is a valid venue kind — the kind table is off-chain.
            venueKind: uint8(bound(inputs.venueKind, 1, type(uint8).max)),
            idleOnly: inputs.idleOnly,
            riskScore: uint8(bound(inputs.riskScore, 0, poolRegistry.MAX_RISK_SCORE())),
            exitLatencySeconds: inputs.exitLatencySeconds,
            elasticityWad: uint64(bound(inputs.elasticityWad, 0, poolRegistry.MAX_ELASTICITY_WAD())),
            entrySlippageWad: uint64(bound(inputs.entrySlippageWad, 0, poolRegistry.MAX_COST_FRACTION_WAD())),
            exitCostWad: uint64(bound(inputs.exitCostWad, 0, poolRegistry.MAX_COST_FRACTION_WAD())),
            chainId: uint64(bound(inputs.chainId, 1, type(uint64).max)),
            adapter: inputs.adapter,
            venueKey: inputs.venueKey,
            metadataHash: inputs.metadataHash
        });

        string memory offchainId = "fuzz:pool";
        PoolId id = poolRegistry.computePoolId(offchainId);

        // Add: config stored, roster grows, epoch bumps; only allocatable pools count toward N.
        vm.prank(users.owner);
        poolRegistry.setPool(vault, offchainId, config);
        assertEq(abi.encode(poolRegistry.configOf(vault, id)), abi.encode(config), "config not stored");
        assertEq(poolRegistry.poolCount(vault), 1, "roster size after add");
        assertEq(poolRegistry.activePoolCount(vault), config.idleOnly ? 0 : 1, "active count after add");
        assertEq(poolRegistry.epoch(vault), 1, "epoch after add");

        // Demote: status flips, active count shrinks, roster keeps the pool.
        vm.prank(users.guardian);
        poolRegistry.demoteToExitOnly(vault, id);
        assertEq(poolRegistry.activePoolCount(vault), 0, "active count after demote");
        assertEq(poolRegistry.poolCount(vault), 1, "roster size after demote");

        // Remove: everything is cleared.
        vm.prank(users.owner);
        poolRegistry.removePool(vault, id);
        assertEq(poolRegistry.poolCount(vault), 0, "roster size after remove");
        assertEq(poolRegistry.activePoolCount(vault), 0, "active count after remove");
        assertEq(
            uint8(poolRegistry.configOf(vault, id).status),
            uint8(IYoPoolRegistry.PoolStatus.NONE),
            "config after remove"
        );
        assertEq(poolRegistry.epoch(vault), 3, "epoch after three writes");
    }

    function testFuzz_PoolsIsolatedByVault(address otherVault) external {
        vm.assume(otherVault != address(0) && otherVault != users.vault);

        string memory offchainId = "fuzz:pool";
        vm.prank(users.owner);
        poolRegistry.setPool(
            users.vault,
            offchainId,
            IYoPoolRegistry.PoolConfig({
                status: IYoPoolRegistry.PoolStatus.ACTIVE,
                venueKind: 1, // ERC4626 per the off-chain kind table
                idleOnly: false,
                riskScore: 80,
                exitLatencySeconds: 1 days,
                elasticityWad: 0.5e18,
                entrySlippageWad: 0.003e18,
                exitCostWad: 0.001e18,
                chainId: 8453,
                adapter: address(yieldAdapter),
                venueKey: bytes32(uint256(uint160(address(mockYieldVault)))),
                metadataHash: 0
            })
        );

        // A pool whitelisted for one vault is invisible to every other vault.
        PoolId id = poolRegistry.computePoolId(offchainId);
        assertEq(poolRegistry.poolCount(otherVault), 0, "roster leak");
        assertEq(poolRegistry.activePoolCount(otherVault), 0, "active count leak");
        assertEq(poolRegistry.epoch(otherVault), 0, "epoch leak");
        assertEq(
            uint8(poolRegistry.configOf(otherVault, id).status), uint8(IYoPoolRegistry.PoolStatus.NONE), "config leak"
        );
    }
}
