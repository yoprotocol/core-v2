// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAuthority } from "src/interfaces/IAuthority.sol";
import { YoRegistry } from "src/YoRegistry.sol";

import { MockERC4626 } from "../../../mocks/MockERC4626.sol";
import { Integration_Test } from "../../Integration.t.sol";

contract YoRegistry_Integration_Fuzz_Test is Integration_Test {
    YoRegistry internal registry;

    function setUp() public override {
        super.setUp();
        YoRegistry impl = new YoRegistry();
        bytes memory initData = abi.encodeCall(YoRegistry.initialize, (users.owner, IAuthority(address(0))));
        registry = YoRegistry(payable(address(new ERC1967Proxy(address(impl), initData))));
    }

    function _newMockVault() internal returns (address) {
        return address(new MockERC4626(IERC20(address(usdc)), "M", "M"));
    }

    /// @dev Any number of distinct add()s yields the same number of entries via listYoVaults.
    function testFuzz_AddRemove_ListLengthMatchesCount(uint8 n) external {
        n = uint8(bound(uint256(n), 1, 30));
        address[] memory vaults = new address[](n);

        vm.startPrank(users.owner);
        for (uint256 i; i < n; ++i) {
            vaults[i] = _newMockVault();
            registry.addYoVault(vaults[i]);
        }
        vm.stopPrank();

        assertEq(registry.listYoVaults().length, n);
        for (uint256 i; i < n; ++i) {
            assertTrue(registry.isYoVault(vaults[i]));
        }
    }

    /// @dev After adding and removing a vault any number of times, isYoVault matches the latest op.
    function testFuzz_AddRemove_Idempotent(uint8 ops) external {
        ops = uint8(bound(uint256(ops), 1, 20));
        address v = _newMockVault();
        bool expected;

        vm.startPrank(users.owner);
        for (uint256 i; i < ops; ++i) {
            if (expected) {
                registry.removeYoVault(v);
                expected = false;
            } else {
                registry.addYoVault(v);
                expected = true;
            }
        }
        vm.stopPrank();

        assertEq(registry.isYoVault(v), expected);
    }
}
