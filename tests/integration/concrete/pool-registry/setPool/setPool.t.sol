// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IYoPoolRegistry, PoolId } from "src/interfaces/IYoPoolRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract SetPool_PoolRegistry_Integration_Concrete_Test is Integration_Test {
    string internal constant OFFCHAIN_ID = "base:erc4626:mock-yield-vault";

    function _config(IYoPoolRegistry.PoolStatus status) private view returns (IYoPoolRegistry.PoolConfig memory) {
        return IYoPoolRegistry.PoolConfig({
            status: status,
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
            metadataHash: keccak256("pool metadata v1")
        });
    }

    function test_RevertWhen_CallerNotOwner() external {
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.eve));
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, _config(IYoPoolRegistry.PoolStatus.ACTIVE));
    }

    function test_WhenVaultZero() external whenCallerOwner {
        vm.expectRevert(IYoPoolRegistry.ZeroAddress.selector);
        poolRegistry.setPool(address(0), OFFCHAIN_ID, _config(IYoPoolRegistry.PoolStatus.ACTIVE));
    }

    function test_WhenAdapterZeroAndNotIdleOnly() external whenCallerOwner {
        IYoPoolRegistry.PoolConfig memory config = _config(IYoPoolRegistry.PoolStatus.ACTIVE);
        config.adapter = address(0);
        vm.expectRevert(IYoPoolRegistry.ZeroAddress.selector);
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, config);
    }

    function test_WhenOffchainIdEmpty() external whenCallerOwner {
        vm.expectRevert(IYoPoolRegistry.EmptyOffchainId.selector);
        poolRegistry.setPool(users.vault, "", _config(IYoPoolRegistry.PoolStatus.ACTIVE));
    }

    function test_WhenStatusNone() external whenCallerOwner {
        vm.expectRevert(IYoPoolRegistry.InvalidStatus.selector);
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, _config(IYoPoolRegistry.PoolStatus.NONE));
    }

    function test_WhenVenueKindZero() external whenCallerOwner {
        IYoPoolRegistry.PoolConfig memory config = _config(IYoPoolRegistry.PoolStatus.ACTIVE);
        config.venueKind = 0;
        vm.expectRevert(IYoPoolRegistry.InvalidVenueKind.selector);
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, config);
    }

    function test_WhenChainIdZero() external whenCallerOwner {
        IYoPoolRegistry.PoolConfig memory config = _config(IYoPoolRegistry.PoolStatus.ACTIVE);
        config.chainId = 0;
        vm.expectRevert(IYoPoolRegistry.InvalidChainId.selector);
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, config);
    }

    function test_WhenRiskScoreExceedsMax() external whenCallerOwner {
        IYoPoolRegistry.PoolConfig memory config = _config(IYoPoolRegistry.PoolStatus.ACTIVE);
        config.riskScore = poolRegistry.MAX_RISK_SCORE() + 1;
        vm.expectRevert(abi.encodeWithSelector(IYoPoolRegistry.InvalidRiskScore.selector, config.riskScore));
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, config);
    }

    function test_WhenElasticityExceedsMax() external whenCallerOwner {
        IYoPoolRegistry.PoolConfig memory config = _config(IYoPoolRegistry.PoolStatus.ACTIVE);
        config.elasticityWad = poolRegistry.MAX_ELASTICITY_WAD() + 1;
        vm.expectRevert(abi.encodeWithSelector(IYoPoolRegistry.InvalidElasticity.selector, config.elasticityWad));
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, config);
    }

    function test_WhenEntrySlippageExceedsMax() external whenCallerOwner {
        IYoPoolRegistry.PoolConfig memory config = _config(IYoPoolRegistry.PoolStatus.ACTIVE);
        config.entrySlippageWad = poolRegistry.MAX_COST_FRACTION_WAD() + 1;
        vm.expectRevert(abi.encodeWithSelector(IYoPoolRegistry.InvalidEntrySlippage.selector, config.entrySlippageWad));
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, config);
    }

    function test_WhenExitCostExceedsMax() external whenCallerOwner {
        IYoPoolRegistry.PoolConfig memory config = _config(IYoPoolRegistry.PoolStatus.ACTIVE);
        config.exitCostWad = poolRegistry.MAX_COST_FRACTION_WAD() + 1;
        vm.expectRevert(abi.encodeWithSelector(IYoPoolRegistry.InvalidExitCost.selector, config.exitCostWad));
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, config);
    }

    modifier whenConfigValid() {
        _;
    }

    modifier givenPoolNew() {
        _;
    }

    function test_GivenStatusActive() external whenCallerOwner whenConfigValid givenPoolNew {
        IYoPoolRegistry.PoolConfig memory config = _config(IYoPoolRegistry.PoolStatus.ACTIVE);
        PoolId id = poolRegistry.computePoolId(OFFCHAIN_ID);

        vm.expectEmit(true, true, true, true, address(poolRegistry));
        emit IYoPoolRegistry.PoolSet(users.vault, id, config, 1, OFFCHAIN_ID);
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, config);

        assertEq(abi.encode(poolRegistry.configOf(users.vault, id)), abi.encode(config), "config not stored");
        assertEq(poolRegistry.poolCount(users.vault), 1, "pool not in roster");
        assertEq(PoolId.unwrap(poolRegistry.poolIds(users.vault)[0]), PoolId.unwrap(id), "roster id mismatch");
        assertEq(poolRegistry.activePoolCount(users.vault), 1, "active count not incremented");
        assertEq(poolRegistry.epoch(users.vault), 1, "epoch not incremented");
    }

    function test_GivenStatusActiveAndIdleOnly() external whenCallerOwner whenConfigValid givenPoolNew {
        IYoPoolRegistry.PoolConfig memory config = _config(IYoPoolRegistry.PoolStatus.ACTIVE);
        config.idleOnly = true;
        config.adapter = address(0); // idle holdings need no execution adapter
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, config);

        PoolId id = poolRegistry.computePoolId(OFFCHAIN_ID);
        assertEq(poolRegistry.configOf(users.vault, id).adapter, address(0), "zero adapter not stored");
        assertEq(poolRegistry.poolCount(users.vault), 1, "pool not in roster");
        assertEq(poolRegistry.activePoolCount(users.vault), 0, "idle pool counted toward N");
    }

    function test_GivenStatusExitOnly() external whenCallerOwner whenConfigValid givenPoolNew {
        IYoPoolRegistry.PoolConfig memory config = _config(IYoPoolRegistry.PoolStatus.EXIT_ONLY);
        PoolId id = poolRegistry.computePoolId(OFFCHAIN_ID);

        vm.expectEmit(true, true, true, true, address(poolRegistry));
        emit IYoPoolRegistry.PoolSet(users.vault, id, config, 1, OFFCHAIN_ID);
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, config);

        assertEq(poolRegistry.poolCount(users.vault), 1, "pool not in roster");
        assertEq(poolRegistry.activePoolCount(users.vault), 0, "active count changed");
    }

    modifier givenPoolExisting() {
        _;
    }

    function test_GivenStatusChangesActiveToExitOnly() external whenCallerOwner whenConfigValid givenPoolExisting {
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, _config(IYoPoolRegistry.PoolStatus.ACTIVE));

        poolRegistry.setPool(users.vault, OFFCHAIN_ID, _config(IYoPoolRegistry.PoolStatus.EXIT_ONLY));

        assertEq(poolRegistry.activePoolCount(users.vault), 0, "active count not decremented");
        assertEq(poolRegistry.poolCount(users.vault), 1, "pool dropped from roster");
    }

    function test_GivenStatusChangesExitOnlyToActive() external whenCallerOwner whenConfigValid givenPoolExisting {
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, _config(IYoPoolRegistry.PoolStatus.EXIT_ONLY));

        poolRegistry.setPool(users.vault, OFFCHAIN_ID, _config(IYoPoolRegistry.PoolStatus.ACTIVE));

        assertEq(poolRegistry.activePoolCount(users.vault), 1, "active count not incremented");
    }

    function test_GivenPoolBecomesIdleOnly() external whenCallerOwner whenConfigValid givenPoolExisting {
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, _config(IYoPoolRegistry.PoolStatus.ACTIVE));

        IYoPoolRegistry.PoolConfig memory updated = _config(IYoPoolRegistry.PoolStatus.ACTIVE);
        updated.idleOnly = true;
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, updated);

        assertEq(poolRegistry.activePoolCount(users.vault), 0, "active count not decremented");
    }

    function test_GivenStatusStaysActive() external whenCallerOwner whenConfigValid givenPoolExisting {
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, _config(IYoPoolRegistry.PoolStatus.ACTIVE));

        IYoPoolRegistry.PoolConfig memory updated = _config(IYoPoolRegistry.PoolStatus.ACTIVE);
        updated.riskScore = 42;
        poolRegistry.setPool(users.vault, OFFCHAIN_ID, updated);

        PoolId id = poolRegistry.computePoolId(OFFCHAIN_ID);
        assertEq(poolRegistry.activePoolCount(users.vault), 1, "active count changed");
        assertEq(poolRegistry.configOf(users.vault, id).riskScore, 42, "config not updated");
    }
}
