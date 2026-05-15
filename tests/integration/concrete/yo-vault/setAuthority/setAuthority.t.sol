// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";
import { IAuthority } from "src/interfaces/IAuthority.sol";

import { MockAuthority } from "../../../../mocks/MockAuthority.sol";
import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract SetAuthorityIntegrationConcreteTest is YoVaultBase_Test {
    function test_RevertWhen_CallerNotAuthorized() external {
        MockAuthority freshAuthority = new MockAuthority();

        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        yoVault.setAuthority(IAuthority(address(freshAuthority)));
    }

    function test_WhenCallerGrantedBySelector_ReplacesAuthority() external {
        MockAuthority freshAuthority = new MockAuthority();
        authority.setAllowed(users.bob, address(yoVault), AuthUpgradeable.setAuthority.selector, true);

        vm.prank(users.bob);
        yoVault.setAuthority(IAuthority(address(freshAuthority)));

        assertEq(address(yoVault.authority()), address(freshAuthority));
    }
}
