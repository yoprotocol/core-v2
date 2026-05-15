// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAuthority } from "src/interfaces/IAuthority.sol";
import { IYoOracle } from "src/interfaces/IYoOracle.sol";
import { YoVault } from "src/YoVault.sol";

import { MockAuthority } from "../../../mocks/MockAuthority.sol";
import { YoVaultHarness } from "../../../mocks/YoVaultHarness.sol";
import { Integration_Test } from "../../Integration.t.sol";

/// @notice Shared base for `YoVault` BTT tests. Deploys the harness behind an ERC-1967 proxy,
///         wires a `MockAuthority`, binds the shared `YoApprovalRegistry`, and pre-funds users.
abstract contract YoVaultBase_Test is Integration_Test {
    /// @dev Selector for `manage(address,bytes,uint256)` — overloaded so we hash explicitly.
    bytes4 internal constant MANAGE_SINGLE_SELECTOR = bytes4(keccak256("manage(address,bytes,uint256)"));
    /// @dev Selector for `manage(address[],bytes[],uint256[])`.
    bytes4 internal constant MANAGE_MULTI_SELECTOR = bytes4(keccak256("manage(address[],bytes[],uint256[])"));

    YoVaultHarness internal yoVault;
    MockAuthority internal authority;

    function _setOraclePrice(uint256 price) internal {
        vm.mockCall(
            yoVault.ORACLE_ADDRESS(),
            abi.encodeWithSelector(IYoOracle.getLatestPrice.selector, address(yoVault)),
            abi.encode(price, uint64(block.timestamp))
        );
    }

    function _authorize(address user, address target, bytes4 sig) internal {
        authority.setAllowed(user, target, sig, true);
    }

    function _revoke(address user, address target, bytes4 sig) internal {
        authority.setAllowed(user, target, sig, false);
    }

    /// @dev Move `assets` of USDC from the vault to the owner by authorising the owner to call
    ///      `usdc.transfer` via `manage`. Used to set up the "vault is short on liquidity" state
    ///      for redeem-queue tests.
    function _moveAssetsFromVault(uint256 assets) internal {
        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, users.owner, assets);
        _authorize(users.owner, address(usdc), IERC20.transfer.selector);
        vm.prank(users.owner);
        yoVault.manage(address(usdc), data, 0);
    }

    function setUp() public virtual override {
        super.setUp();

        // Deploy implementation + proxy. OZ 5.6 requires atomic init via the proxy constructor.
        YoVaultHarness impl = new YoVaultHarness();
        bytes memory initData =
            abi.encodeCall(YoVault.initialize, (IERC20(address(usdc)), users.owner, "Yo USDC Vault", "yoUSDC"));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        yoVault = YoVaultHarness(payable(address(proxy)));
        vm.label(address(impl), "YoVaultImpl");
        vm.label(address(yoVault), "YoVault");

        // Wire authority.
        authority = new MockAuthority();
        vm.label(address(authority), "MockAuthority");
        vm.prank(users.owner);
        yoVault.setAuthority(IAuthority(address(authority)));

        // Grant the operator the standard hot-key selector set. The inner per-target
        // checks inside `manage` are left to individual tests so they can exercise the
        // "outer auth OK, inner not OK" branch.
        authority.setAllowed(users.operator, address(yoVault), MANAGE_SINGLE_SELECTOR, true);
        authority.setAllowed(users.operator, address(yoVault), MANAGE_MULTI_SELECTOR, true);
        authority.setAllowed(users.operator, address(yoVault), YoVault.approveToken.selector, true);

        // Bind the shared approval registry.
        vm.prank(users.owner);
        yoVault.setApprovalRegistry(approvalRegistry);

        // Mock the oracle at 1:1 (1e6 for 6-decimal USDC) so deposits/redeems are 1-share-per-1-asset.
        _setOraclePrice(1e6);

        // Pre-fund alice (depositor) and bob (fee-recipient / second-party) and pre-approve the vault.
        usdc.mint(users.alice, 1_000_000e6);
        usdc.mint(users.bob, 1_000_000e6);
        vm.prank(users.alice);
        usdc.approve(address(yoVault), type(uint256).max);
        vm.prank(users.bob);
        usdc.approve(address(yoVault), type(uint256).max);
    }
}
