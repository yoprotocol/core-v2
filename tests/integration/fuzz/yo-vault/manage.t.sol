// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";
import { Errors } from "src/libraries/Errors.sol";

import { MockTarget } from "../../../mocks/MockTarget.sol";
import { YoVaultBase_Test } from "../../concrete/yo-vault/YoVaultBase.t.sol";

contract Manage_YoVault_Integration_Fuzz_Test is YoVaultBase_Test {
    /// @dev Any caller without an auth grant on `manage(address,bytes,uint256)` reverts.
    function testFuzz_ManageSingle_RevertsForUngrantedCaller(address caller, uint256 value) external {
        vm.assume(caller != users.owner && caller != users.operator);
        value = bound(value, 0, 100 ether);
        vm.deal(address(yoVault), value);

        bytes memory data = abi.encodeCall(IERC20.transfer, (users.eve, 0));
        vm.prank(caller);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        yoVault.manage(address(usdc), data, 0);
    }

    /// @dev Granting (operator, target, selector) lets the operator forward a call and the value
    ///      flows through to the target.
    function testFuzz_ManageSingle_ForwardsValueOnGrant(uint256 value, uint256 arg) external {
        value = bound(value, 0, 100 ether);
        vm.deal(address(yoVault), value);

        MockTarget target = new MockTarget();
        bytes4 sel = MockTarget.someFunction.selector;
        _authorize(users.operator, address(target), sel);

        bytes memory data = abi.encodeWithSelector(sel, arg);
        vm.prank(users.operator);
        yoVault.manage(address(target), data, value);

        assertEq(target.value(), arg, "arg forwarded");
        assertEq(address(target).balance, value, "value forwarded");
    }

    /// @dev If ANY element of a multi-call lacks an inner grant, the entire batch reverts.
    function testFuzz_ManageMulti_AllOrNothing(uint8 nGranted) external {
        nGranted = uint8(bound(uint256(nGranted), 0, 3));
        uint256 N = 4;

        address[] memory targets = new address[](N);
        bytes[] memory data = new bytes[](N);
        uint256[] memory values = new uint256[](N);
        bytes4 sel = MockTarget.someFunction.selector;

        for (uint256 i; i < N; ++i) {
            targets[i] = address(new MockTarget());
            data[i] = abi.encodeWithSelector(sel, i);
        }
        // Grant only the first `nGranted` legs.
        for (uint256 i; i < nGranted; ++i) {
            _authorize(users.operator, targets[i], sel);
        }

        if (nGranted == N) {
            vm.prank(users.operator);
            yoVault.manage(targets, data, values);
            // All legs executed.
            for (uint256 i; i < N; ++i) {
                assertEq(MockTarget(targets[i]).value(), i);
            }
        } else {
            vm.prank(users.operator);
            vm.expectRevert(
                abi.encodeWithSelector(Errors.TargetMethodNotAuthorized.selector, targets[nGranted], sel)
            );
            yoVault.manage(targets, data, values);
            // No leg observed a state change.
            for (uint256 i; i < N; ++i) {
                assertEq(MockTarget(targets[i]).value(), 0);
            }
        }
    }
}
