// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { IAuthority } from "src/interfaces/IAuthority.sol";
import { YoToken } from "src/YoToken.sol";

import { MockAuthority } from "../../../mocks/MockAuthority.sol";
import { Integration_Test } from "../../Integration.t.sol";

/// @notice Shared base for `YoToken` BTT tests. The token grants `_update` to the owner only at
///         init; tests opt-in additional callers via `_grantTransfer`.
abstract contract YoTokenBase_Test is Integration_Test {
    YoToken internal token;
    MockAuthority internal authority;

    /// @dev Grant `user` the right to call a specific external selector. `_update` is internal,
    ///      so the `requiresAuth` modifier sees `msg.sig` of whatever public entry point invoked it
    ///      (transfer / transferFrom / burn).
    function _grantSelector(address user, bytes4 sel) internal {
        authority.setAllowed(user, address(token), sel, true);
    }

    function setUp() public virtual override {
        super.setUp();

        YoToken impl = new YoToken();
        bytes memory initData = abi.encodeCall(YoToken.initialize, (users.owner, "YoToken", "YO"));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        token = YoToken(address(proxy));
        vm.label(address(impl), "YoTokenImpl");
        vm.label(address(token), "YoToken");

        authority = new MockAuthority();
        vm.label(address(authority), "MockAuthority");
        vm.prank(users.owner);
        token.setAuthority(IAuthority(address(authority)));
    }
}
