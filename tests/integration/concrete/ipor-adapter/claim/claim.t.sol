// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { IIPORWithdrawManager } from "src/interfaces/external/IIPORWithdrawManager.sol";
import { IYoIPORAdapter } from "src/interfaces/IYoIPORAdapter.sol";

import { MockIIPORPlasmaVault } from "../../../../mocks/MockIIPORPlasmaVault.sol";
import { MockIIPORWithdrawManager } from "../../../../mocks/MockIIPORWithdrawManager.sol";
import { Integration_Test } from "../../../Integration.t.sol";

contract ClaimIPORIntegrationConcreteTest is Integration_Test {
    uint256 internal constant SHARES = 5_000e6;

    function _seedPosition(uint256 assets) internal returns (uint256 shares) {
        vm.prank(users.vault);
        shares = iporAdapter.deposit(mockPlasmaVault, assets);
    }

    /// @dev Simulate the full async sequence: place a request as the vault (mirrors the
    ///      `manage()`-path used in production), advance past `requestTimestamp`, and have the
    ///      keeper release covering funds. After this, `claim(shares)` should succeed within the
    ///      same window.
    function _placeAndReleaseRequest(uint256 shares) internal {
        vm.prank(users.vault);
        mockIPORWithdrawManager.requestShares(shares);

        vm.warp(block.timestamp + 1);
        mockIPORWithdrawManager.releaseFunds(block.timestamp, shares);
    }

    function test_RevertWhen_SharesZero() external whenCallerVault {
        vm.expectRevert(IYoIPORAdapter.InvalidAmount.selector);
        iporAdapter.claim(mockPlasmaVault, 0);
    }

    function test_RevertWhen_PlasmaVaultNotAllowed() external whenCallerVault {
        MockIIPORWithdrawManager otherManager = new MockIIPORWithdrawManager(defaults.IPOR_WITHDRAW_WINDOW());
        MockIIPORPlasmaVault other = new MockIIPORPlasmaVault(usdc, "Other Plasma", "oPV", otherManager);

        vm.expectRevert(abi.encodeWithSelector(IYoIPORAdapter.VaultNotAllowed.selector, other));
        iporAdapter.claim(other, SHARES);
    }

    function test_RevertGiven_NoPendingRequest() external {
        _seedPosition(defaults.SUPPLY_AMOUNT());

        vm.prank(users.vault);
        vm.expectRevert(MockIIPORWithdrawManager.NoEligibleRequest.selector);
        iporAdapter.claim(mockPlasmaVault, SHARES);
    }

    function test_RevertGiven_BeforeKeeperRelease() external {
        uint256 shares = _seedPosition(defaults.SUPPLY_AMOUNT());

        vm.prank(users.vault);
        mockIPORWithdrawManager.requestShares(shares);
        vm.warp(block.timestamp + 1);
        // Keeper has NOT released — claim must revert.

        vm.prank(users.vault);
        vm.expectRevert(MockIIPORWithdrawManager.NoEligibleRequest.selector);
        iporAdapter.claim(mockPlasmaVault, shares);
    }

    function test_RevertGiven_ClaimWindowExpired() external {
        uint256 shares = _seedPosition(defaults.SUPPLY_AMOUNT());
        _placeAndReleaseRequest(shares);

        // Jump past `endWithdrawWindowTimestamp`. The vault's request timestamp was approximately
        // `FEB_1_2025`, plus 1s warp to enter the window, plus the window length must elapse.
        vm.warp(block.timestamp + defaults.IPOR_WITHDRAW_WINDOW() + 1);

        vm.prank(users.vault);
        vm.expectRevert(MockIIPORWithdrawManager.NoEligibleRequest.selector);
        iporAdapter.claim(mockPlasmaVault, shares);
    }

    function test_RevertGiven_VaultHasNotApprovedAdapterOnShares() external {
        uint256 shares = _seedPosition(defaults.SUPPLY_AMOUNT());
        _placeAndReleaseRequest(shares);

        vm.prank(users.vault);
        mockPlasmaVault.approve(address(iporAdapter), 0);

        vm.prank(users.vault);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        iporAdapter.claim(mockPlasmaVault, shares);
    }

    function test_GivenWindowAndRelease_RedeemsToVault() external {
        uint256 supplied = defaults.SUPPLY_AMOUNT();
        uint256 shares = _seedPosition(supplied);
        _placeAndReleaseRequest(shares);

        uint256 vaultBalBefore = usdc.balanceOf(users.vault);
        uint256 sharesBefore = mockPlasmaVault.balanceOf(users.vault);

        vm.prank(users.vault);
        uint256 assetsReceived = iporAdapter.claim(mockPlasmaVault, shares);

        // Mock PlasmaVault is 1:1 so the round-trip is lossless.
        assertEq(assetsReceived, supplied, "assets received");
        assertEq(usdc.balanceOf(users.vault), vaultBalBefore + supplied, "vault USDC restored");
        assertEq(mockPlasmaVault.balanceOf(users.vault), sharesBefore - shares, "vault shares burned");

        // Adapter holds nothing.
        assertZeroBalance(address(usdc), address(iporAdapter));
        assertZeroBalance(address(mockPlasmaVault), address(iporAdapter));

        // Request slot drained.
        IIPORWithdrawManager.WithdrawRequestInfo memory info = mockIPORWithdrawManager.requestInfo(users.vault);
        assertEq(info.shares, 0, "request slot drained");
    }
}
