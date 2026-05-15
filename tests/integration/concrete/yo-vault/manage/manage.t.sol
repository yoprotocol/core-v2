// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AuthUpgradeable } from "src/base/AuthUpgradeable.sol";
import { Errors } from "src/libraries/Errors.sol";

import { MockTarget } from "../../../../mocks/MockTarget.sol";
import { YoVaultBase_Test } from "../YoVaultBase.t.sol";

contract ManageIntegrationConcreteTest is YoVaultBase_Test {
    bytes4 private constant TRANSFER_SELECTOR = IERC20.transfer.selector;
    bytes4 private constant TARGET_SELECTOR = MockTarget.someFunction.selector;

    /*//////////////////////////////////////////////////////////////////////////
                                  SINGLE-CALL FORM
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_CallerNotAuthorized() external {
        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        yoVault.manage(address(usdc), abi.encodeCall(IERC20.transfer, (users.eve, 0)), 0);
    }

    function test_RevertWhen_TargetSelectorNotGranted() external {
        bytes memory data = abi.encodeCall(IERC20.transfer, (users.eve, 0));
        vm.prank(users.operator);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.TargetMethodNotAuthorized.selector, address(usdc), TRANSFER_SELECTOR)
        );
        yoVault.manage(address(usdc), data, 0);
    }

    function test_GivenTargetSelectorGranted_ForwardsAndReturns() external {
        usdc.mint(address(yoVault), 1000e6);
        _authorize(users.operator, address(usdc), TRANSFER_SELECTOR);

        uint256 amount = 100e6;
        bytes memory data = abi.encodeCall(IERC20.transfer, (users.eve, amount));

        vm.prank(users.operator);
        bytes memory ret = yoVault.manage(address(usdc), data, 0);

        assertEq(usdc.balanceOf(users.eve), amount, "eve received");
        assertEq(usdc.balanceOf(address(yoVault)), 1000e6 - amount, "vault drained");
        assertEq(abi.decode(ret, (bool)), true, "transfer return");
    }

    function test_GivenSingleCallWithValue_ForwardsETH() external {
        MockTarget target = new MockTarget();
        _authorize(users.operator, address(target), TARGET_SELECTOR);

        uint256 value = 1 ether;
        vm.deal(address(yoVault), value);

        bytes memory data = abi.encodeWithSelector(TARGET_SELECTOR, uint256(42));

        vm.prank(users.operator);
        yoVault.manage(address(target), data, value);

        assertEq(target.value(), 42);
        assertEq(address(target).balance, value);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  MULTI-CALL FORM
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_MultiCall_CallerNotAuthorized() external {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        uint256[] memory values = new uint256[](1);
        targets[0] = address(usdc);
        data[0] = abi.encodeCall(IERC20.transfer, (users.eve, 0));
        values[0] = 0;

        vm.prank(users.eve);
        vm.expectRevert(AuthUpgradeable.Unauthorized.selector);
        yoVault.manage(targets, data, values);
    }

    function test_RevertWhen_MultiCall_TargetSelectorNotGranted() external {
        MockTarget t0 = new MockTarget();
        MockTarget t1 = new MockTarget();
        // Grant only the first leg; the second leg should trip the check.
        _authorize(users.operator, address(t0), TARGET_SELECTOR);

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);
        targets[0] = address(t0);
        targets[1] = address(t1);
        data[0] = abi.encodeWithSelector(TARGET_SELECTOR, uint256(1));
        data[1] = abi.encodeWithSelector(TARGET_SELECTOR, uint256(2));

        vm.prank(users.operator);
        vm.expectRevert(abi.encodeWithSelector(Errors.TargetMethodNotAuthorized.selector, address(t1), TARGET_SELECTOR));
        yoVault.manage(targets, data, values);
    }

    function test_GivenMultiCall_AllSelectorsGranted_Forwards() external {
        MockTarget t0 = new MockTarget();
        MockTarget t1 = new MockTarget();
        _authorize(users.operator, address(t0), TARGET_SELECTOR);
        _authorize(users.operator, address(t1), TARGET_SELECTOR);

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);
        targets[0] = address(t0);
        targets[1] = address(t1);
        data[0] = abi.encodeWithSelector(TARGET_SELECTOR, uint256(42));
        data[1] = abi.encodeWithSelector(TARGET_SELECTOR, uint256(43));

        vm.prank(users.operator);
        yoVault.manage(targets, data, values);

        assertEq(t0.value(), 42);
        assertEq(t1.value(), 43);
    }
}
