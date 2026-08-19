// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoPoolRegistry, PoolId } from "src/interfaces/IYoPoolRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract Views_PoolRegistry_Integration_Concrete_Test is Integration_Test {
    string internal constant POOL_A = "base:erc4626:mock-yield-vault";
    string internal constant POOL_B = "base:morpho:usdc-market-a";
    string internal constant POOL_C = "base:holding:usdt";

    function _seedPool(string memory offchainId, IYoPoolRegistry.PoolStatus status, bool idleOnly) private {
        vm.prank(users.owner);
        poolRegistry.setPool(
            users.vault,
            offchainId,
            IYoPoolRegistry.PoolConfig({
                status: status,
                venueKind: 1, // ERC4626 per the off-chain kind table
                idleOnly: idleOnly,
                riskScore: 80,
                exitLatencySeconds: 1 days,
                elasticityWad: 0.5e18,
                entrySlippageWad: 0.003e18,
                exitCostWad: 0.001e18,
                chainId: 8453,
                adapter: idleOnly ? address(0) : address(yieldAdapter),
                venueKey: bytes32(uint256(uint160(address(mockYieldVault)))),
                metadataHash: keccak256("pool metadata v1")
            })
        );
    }

    function test_GivenEmptyRoster() external view {
        PoolId id = poolRegistry.computePoolId(POOL_A);

        assertEq(poolRegistry.poolCount(users.vault), 0, "pool count not zero");
        assertEq(poolRegistry.activePoolCount(users.vault), 0, "active count not zero");
        assertEq(poolRegistry.poolIds(users.vault).length, 0, "pool ids not empty");
        assertEq(poolRegistry.pools(users.vault).length, 0, "pools not empty");
        assertEq(poolRegistry.epoch(users.vault), 0, "epoch not zero");
        assertEq(
            uint8(poolRegistry.configOf(users.vault, id).status),
            uint8(IYoPoolRegistry.PoolStatus.NONE),
            "config not empty"
        );
    }

    function test_GivenPopulatedRoster() external {
        _seedPool(POOL_A, IYoPoolRegistry.PoolStatus.ACTIVE, false);
        _seedPool(POOL_B, IYoPoolRegistry.PoolStatus.EXIT_ONLY, false);
        _seedPool(POOL_C, IYoPoolRegistry.PoolStatus.ACTIVE, true);

        // The idle holding sits on the roster but holds no whitelist slot: N counts only A.
        assertEq(poolRegistry.poolCount(users.vault), 3, "pool count mismatch");
        assertEq(poolRegistry.activePoolCount(users.vault), 1, "active count mismatch");

        PoolId idA = poolRegistry.computePoolId(POOL_A);
        PoolId idB = poolRegistry.computePoolId(POOL_B);
        PoolId idC = poolRegistry.computePoolId(POOL_C);
        assertEq(PoolId.unwrap(idA), keccak256(bytes(POOL_A)), "id derivation mismatch");

        PoolId[] memory ids = poolRegistry.poolIds(users.vault);
        assertEq(ids.length, 3, "pool ids length mismatch");
        assertEq(PoolId.unwrap(ids[0]), PoolId.unwrap(idA), "first id mismatch");
        assertEq(PoolId.unwrap(ids[1]), PoolId.unwrap(idB), "second id mismatch");
        assertEq(PoolId.unwrap(ids[2]), PoolId.unwrap(idC), "third id mismatch");

        // The one-call roster view pairs each id with its stored config, in poolIds order.
        IYoPoolRegistry.Pool[] memory pools = poolRegistry.pools(users.vault);
        assertEq(pools.length, 3, "pools length mismatch");
        for (uint256 i = 0; i < pools.length; ++i) {
            assertEq(PoolId.unwrap(pools[i].id), PoolId.unwrap(ids[i]), "pools id mismatch");
            assertEq(
                abi.encode(pools[i].config),
                abi.encode(poolRegistry.configOf(users.vault, ids[i])),
                "pools config mismatch"
            );
        }
        assertEq(uint8(pools[2].config.status), uint8(IYoPoolRegistry.PoolStatus.ACTIVE), "pool C status mismatch");
        assertTrue(pools[2].config.idleOnly, "pool C idleOnly mismatch");

        // Demote A, then remove it: counts, roster, and config must stay consistent.
        vm.prank(users.guardian);
        poolRegistry.demoteToExitOnly(users.vault, idA);
        assertEq(poolRegistry.activePoolCount(users.vault), 0, "active count after demote");
        assertEq(poolRegistry.poolCount(users.vault), 3, "pool count after demote");

        vm.prank(users.owner);
        poolRegistry.removePool(users.vault, idA);
        assertEq(poolRegistry.poolCount(users.vault), 2, "pool count after remove");
        ids = poolRegistry.poolIds(users.vault);
        // EnumerableSet removal is swap-and-pop: C takes A's slot.
        assertEq(PoolId.unwrap(ids[0]), PoolId.unwrap(idC), "roster after remove");
        assertEq(PoolId.unwrap(ids[1]), PoolId.unwrap(idB), "roster after remove");
        assertEq(
            uint8(poolRegistry.configOf(users.vault, idA).status),
            uint8(IYoPoolRegistry.PoolStatus.NONE),
            "config after remove"
        );
        assertEq(poolRegistry.epoch(users.vault), 5, "epoch after five writes");
    }
}
