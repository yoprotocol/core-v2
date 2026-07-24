// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IYoMidnightAdapter } from "src/interfaces/IYoMidnightAdapter.sol";

import { Midnight_Integration_Shared } from "../../../MidnightIntegration.t.sol";

contract CancelGroup_Integration_Concrete_Test is Midnight_Integration_Shared {
    function test_RevertWhen_AdapterNotAuthorized() external {
        // Revoke the adapter's Midnight delegation; setConsumed then rejects the call.
        vm.prank(users.vault);
        mockMidnight.setIsAuthorized(address(midnightAdapter), false, users.vault);

        vm.prank(users.vault);
        vm.expectRevert(bytes("unauthorized"));
        midnightAdapter.cancelGroup(GROUP_A);
    }

    function test_WhenAuthorized_SetsConsumedMax() external whenCallerVault {
        vm.expectEmit(true, false, false, true, address(midnightAdapter));
        emit IYoMidnightAdapter.GroupCancelled(users.vault, GROUP_A);
        midnightAdapter.cancelGroup(GROUP_A);

        assertEq(mockMidnight.consumed(users.vault, GROUP_A), type(uint128).max, "group consumed maxed");
    }
}
