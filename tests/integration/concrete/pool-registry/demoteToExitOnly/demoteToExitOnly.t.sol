// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoPoolRegistry, PoolId } from "src/interfaces/IYoPoolRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract DemoteToExitOnly_PoolRegistry_Integration_Concrete_Test is Integration_Test {
    string internal constant OFFCHAIN_ID = "base:erc4626:mock-yield-vault";

    PoolId internal id;

    function setUp() public override {
        Integration_Test.setUp();
        id = poolRegistry.computePoolId(OFFCHAIN_ID);
    }

    function _seedPool(IYoPoolRegistry.PoolStatus status) private {
        _seedPool(status, false);
    }

    function _seedPool(IYoPoolRegistry.PoolStatus status, bool idleOnly) private {
        vm.prank(users.owner);
        poolRegistry.setPool(
            users.vault,
            OFFCHAIN_ID,
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
                adapter: address(yieldAdapter),
                venueKey: bytes32(uint256(uint160(address(mockYieldVault)))),
                metadataHash: keccak256("pool metadata v1")
            })
        );
    }

    function test_WhenCallerNeitherGuardianNorOwner() external {
        _seedPool(IYoPoolRegistry.PoolStatus.ACTIVE);

        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(IYoPoolRegistry.UnauthorizedCaller.selector, users.eve));
        poolRegistry.demoteToExitOnly(users.vault, id);
    }

    modifier whenCallerAuthorized() {
        _;
    }

    function test_GivenPoolUnknown() external whenCallerAuthorized {
        vm.prank(users.guardian);
        vm.expectRevert(abi.encodeWithSelector(IYoPoolRegistry.PoolNotActive.selector, id));
        poolRegistry.demoteToExitOnly(users.vault, id);
    }

    function test_GivenPoolExitOnly() external whenCallerAuthorized {
        _seedPool(IYoPoolRegistry.PoolStatus.EXIT_ONLY);

        vm.prank(users.guardian);
        vm.expectRevert(abi.encodeWithSelector(IYoPoolRegistry.PoolNotActive.selector, id));
        poolRegistry.demoteToExitOnly(users.vault, id);
    }

    function test_GivenPoolActiveAndIdleOnly() external whenCallerAuthorized {
        _seedPool(IYoPoolRegistry.PoolStatus.ACTIVE, true);

        vm.prank(users.guardian);
        poolRegistry.demoteToExitOnly(users.vault, id);

        assertEq(
            uint8(poolRegistry.configOf(users.vault, id).status),
            uint8(IYoPoolRegistry.PoolStatus.EXIT_ONLY),
            "status not exit only"
        );
        // An idle holding never held a whitelist slot, so N is untouched.
        assertEq(poolRegistry.activePoolCount(users.vault), 0, "active count changed");
    }

    modifier givenPoolActive() {
        _seedPool(IYoPoolRegistry.PoolStatus.ACTIVE);
        _;
    }

    function test_WhenCallerGuardian() external whenCallerAuthorized givenPoolActive {
        vm.expectEmit(true, true, true, true, address(poolRegistry));
        emit IYoPoolRegistry.PoolDemoted(users.vault, id, users.guardian, 2);
        vm.prank(users.guardian);
        poolRegistry.demoteToExitOnly(users.vault, id);

        assertEq(
            uint8(poolRegistry.configOf(users.vault, id).status),
            uint8(IYoPoolRegistry.PoolStatus.EXIT_ONLY),
            "status not exit only"
        );
        assertEq(poolRegistry.activePoolCount(users.vault), 0, "active count not decremented");
        assertEq(poolRegistry.poolCount(users.vault), 1, "pool dropped from roster");
        assertEq(poolRegistry.epoch(users.vault), 2, "epoch not incremented");
    }

    function test_WhenCallerOwner() external whenCallerAuthorized givenPoolActive {
        vm.prank(users.owner);
        poolRegistry.demoteToExitOnly(users.vault, id);

        assertEq(
            uint8(poolRegistry.configOf(users.vault, id).status),
            uint8(IYoPoolRegistry.PoolStatus.EXIT_ONLY),
            "status not exit only"
        );
    }
}
