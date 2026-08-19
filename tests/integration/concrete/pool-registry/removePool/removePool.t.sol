// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IYoPoolRegistry, PoolId } from "src/interfaces/IYoPoolRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract RemovePool_PoolRegistry_Integration_Concrete_Test is Integration_Test {
    string internal constant OFFCHAIN_ID = "base:erc4626:mock-yield-vault";

    PoolId internal id;

    function setUp() public override {
        Integration_Test.setUp();
        id = poolRegistry.computePoolId(OFFCHAIN_ID);
    }

    function _seedPool(IYoPoolRegistry.PoolStatus status) private {
        poolRegistry.setPool(
            users.vault,
            OFFCHAIN_ID,
            IYoPoolRegistry.PoolConfig({
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
            })
        );
    }

    function test_RevertWhen_CallerNotOwner() external {
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.eve));
        poolRegistry.removePool(users.vault, id);
    }

    function test_GivenPoolActive() external whenCallerOwner {
        _seedPool(IYoPoolRegistry.PoolStatus.ACTIVE);

        vm.expectRevert(abi.encodeWithSelector(IYoPoolRegistry.PoolActive.selector, id));
        poolRegistry.removePool(users.vault, id);
    }

    function test_GivenPoolUnknown() external whenCallerOwner {
        vm.expectRevert(abi.encodeWithSelector(IYoPoolRegistry.PoolNotFound.selector, id));
        poolRegistry.removePool(users.vault, id);
    }

    function test_GivenPoolExitOnly() external whenCallerOwner {
        _seedPool(IYoPoolRegistry.PoolStatus.EXIT_ONLY);

        vm.expectEmit(true, true, true, true, address(poolRegistry));
        emit IYoPoolRegistry.PoolRemoved(users.vault, id, 2);
        poolRegistry.removePool(users.vault, id);

        assertEq(poolRegistry.poolCount(users.vault), 0, "pool still in roster");
        assertEq(
            uint8(poolRegistry.configOf(users.vault, id).status),
            uint8(IYoPoolRegistry.PoolStatus.NONE),
            "config not deleted"
        );
        assertEq(poolRegistry.activePoolCount(users.vault), 0, "active count changed");
        assertEq(poolRegistry.epoch(users.vault), 2, "epoch not incremented");
    }
}
