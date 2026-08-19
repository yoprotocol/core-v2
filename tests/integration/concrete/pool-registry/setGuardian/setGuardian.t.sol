// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IYoPoolRegistry } from "src/interfaces/IYoPoolRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract SetGuardian_PoolRegistry_Integration_Concrete_Test is Integration_Test {
    function test_RevertWhen_CallerNotOwner() external {
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.eve));
        poolRegistry.setGuardian(users.eve);
    }

    function test_WhenNewGuardianZero() external whenCallerOwner {
        vm.expectEmit(true, true, true, true, address(poolRegistry));
        emit IYoPoolRegistry.GuardianSet(address(0));
        poolRegistry.setGuardian(address(0));

        assertEq(poolRegistry.guardian(), address(0), "guardian not cleared");
    }

    function test_WhenNewGuardianNotZero() external whenCallerOwner {
        vm.expectEmit(true, true, true, true, address(poolRegistry));
        emit IYoPoolRegistry.GuardianSet(users.alice);
        poolRegistry.setGuardian(users.alice);

        assertEq(poolRegistry.guardian(), users.alice, "guardian not set");
    }
}
