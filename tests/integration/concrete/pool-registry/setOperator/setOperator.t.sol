// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IYoPoolRegistry } from "src/interfaces/IYoPoolRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract SetOperatorPoolRegistryIntegrationConcreteTest is Integration_Test {
    function test_RevertWhen_CallerNotOwner() external {
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.eve));
        poolRegistry.setOperator(users.eve);
    }

    function test_WhenNewOperatorZero() external whenCallerOwner {
        vm.expectEmit(true, true, true, true, address(poolRegistry));
        emit IYoPoolRegistry.OperatorSet(address(0));
        poolRegistry.setOperator(address(0));

        assertEq(poolRegistry.operator(), address(0), "operator not cleared");
    }

    function test_WhenNewOperatorNotZero() external whenCallerOwner {
        vm.expectEmit(true, true, true, true, address(poolRegistry));
        emit IYoPoolRegistry.OperatorSet(users.alice);
        poolRegistry.setOperator(users.alice);

        assertEq(poolRegistry.operator(), users.alice, "operator not set");
    }
}
