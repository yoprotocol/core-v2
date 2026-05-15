// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IYoOracle } from "src/interfaces/IYoOracle.sol";

import { YoOracleBase_Test } from "../YoOracleBase.t.sol";

contract SetUpdaterIntegrationConcreteTest is YoOracleBase_Test {
    function test_WhenOwner_UpdatesUpdater() external {
        vm.expectEmit(true, true, true, true, address(oracle));
        emit IYoOracle.UpdaterChanged(users.operator, users.bob);

        vm.prank(users.owner);
        oracle.setUpdater(users.bob);

        assertEq(oracle.updater(), users.bob);
    }

    function test_RevertWhen_CallerNotOwner() external {
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.eve));
        oracle.setUpdater(users.bob);
    }

    function test_RevertWhen_UpdaterZero() external {
        vm.prank(users.owner);
        vm.expectRevert(IYoOracle.InvalidConfig.selector);
        oracle.setUpdater(address(0));
    }
}
