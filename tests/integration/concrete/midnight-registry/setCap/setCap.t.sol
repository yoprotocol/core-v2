// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IYoMidnightRegistry } from "src/interfaces/IYoMidnightRegistry.sol";
import { YoMidnightRegistry } from "src/registries/YoMidnightRegistry.sol";

import { Integration_Test } from "../../../Integration.t.sol";

contract SetCap_MidnightRegistry_Integration_Concrete_Test is Integration_Test {
    uint256 internal constant CAP = 20_000e6;

    YoMidnightRegistry internal midnightRegistry;

    function setUp() public override {
        Integration_Test.setUp();
        midnightRegistry = new YoMidnightRegistry(users.owner);
    }

    function test_RevertWhen_CallerNotOwner() external {
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.eve));
        midnightRegistry.setCap(users.vault, CAP);
    }

    function test_WhenVaultZero() external whenCallerOwner {
        vm.expectRevert(IYoMidnightRegistry.ZeroAddress.selector);
        midnightRegistry.setCap(address(0), CAP);
    }

    function test_WhenVaultNonZero() external whenCallerOwner whenVaultNotZero {
        vm.expectEmit(true, true, true, true, address(midnightRegistry));
        emit IYoMidnightRegistry.CapSet(users.vault, CAP);

        midnightRegistry.setCap(users.vault, CAP);

        assertEq(midnightRegistry.cap(users.vault), CAP, "cap");
    }
}
