// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Integration_Test } from "../../../Integration.t.sol";

contract MaxApproval_Integration_Concrete_Test is Integration_Test {
    address private constant TOKEN = address(0x1111);
    address private constant SPENDER = address(0x2222);

    function test_GivenNoEntrySet() external view {
        assertEq(approvalRegistry.maxApproval(users.vault, TOKEN, SPENDER), 0);
    }

    function test_GivenAmountClearedBackToZero() external {
        _setApproval(users.vault, TOKEN, SPENDER, 100);
        _setApproval(users.vault, TOKEN, SPENDER, 0);
        assertEq(approvalRegistry.maxApproval(users.vault, TOKEN, SPENDER), 0);
    }

    function test_GivenNonZeroAmount_ReturnsConfigured() external {
        uint256 cap = defaults.APPROVAL_CAP();
        _setApproval(users.vault, TOKEN, SPENDER, cap);
        assertEq(approvalRegistry.maxApproval(users.vault, TOKEN, SPENDER), cap);
    }

    function test_GivenNonZeroAmount_DistinctVaults() external {
        address otherVault = makeAddr("OtherVault");
        _setApproval(users.vault, TOKEN, SPENDER, 100);
        // Per-vault keying: an entry on `users.vault` must NOT leak to `otherVault`.
        assertEq(approvalRegistry.maxApproval(otherVault, TOKEN, SPENDER), 0);
        assertEq(approvalRegistry.maxApproval(users.vault, TOKEN, SPENDER), 100);
    }
}
