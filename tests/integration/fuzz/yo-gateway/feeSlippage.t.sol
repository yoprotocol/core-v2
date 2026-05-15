// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAuthority } from "src/interfaces/IAuthority.sol";
import { Errors } from "src/libraries/Errors.sol";
import { YoGateway } from "src/YoGateway.sol";
import { YoRegistry } from "src/YoRegistry.sol";

import { MockAuthority } from "../../../mocks/MockAuthority.sol";
import { MockFeeYoVault } from "../../../mocks/MockFeeYoVault.sol";
import { Integration_Test } from "../../Integration.t.sol";

/// @notice Regression for the audit finding: gateway's slippage check must compare against the
///         **net** amount the receiver gets (post-fee), not the gross value `requestRedeem` returns.
///         Setup uses `MockFeeYoVault`, which reproduces the V3 YoVault behavior of returning gross
///         while delivering net.
contract FeeSlippage_YoGateway_Integration_Fuzz_Test is Integration_Test {
    YoRegistry internal registry;
    YoGateway internal gateway;
    MockFeeYoVault internal feeVault;

    uint256 internal constant FEE_BPS = 9e16; // 9% withdrawal fee — within YoVault's MAX_FEE (10%)

    function setUp() public override {
        super.setUp();

        // Registry behind ERC1967 proxy.
        YoRegistry regImpl = new YoRegistry();
        bytes memory regInit = abi.encodeCall(YoRegistry.initialize, (users.owner, IAuthority(address(0))));
        registry = YoRegistry(payable(address(new ERC1967Proxy(address(regImpl), regInit))));

        // Authority + admin grant.
        MockAuthority auth = new MockAuthority();
        vm.prank(users.owner);
        registry.setAuthority(IAuthority(address(auth)));

        // Gateway behind ERC1967 proxy.
        YoGateway gwImpl = new YoGateway();
        bytes memory gwInit = abi.encodeCall(YoGateway.initialize, (address(registry)));
        gateway = YoGateway(payable(address(new ERC1967Proxy(address(gwImpl), gwInit))));

        // Fee vault + allowlist.
        feeVault = new MockFeeYoVault(IERC20(address(usdc)), "Mock Fee Vault", "mFV", FEE_BPS);
        vm.prank(users.owner);
        registry.addYoVault(address(feeVault));

        // Fund alice + approvals.
        usdc.mint(users.alice, 1_000_000e6);
        vm.startPrank(users.alice);
        usdc.approve(address(feeVault), type(uint256).max);
        feeVault.approve(address(gateway), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev `minAssetsOut` set above the *net* preview must revert. Without the fix, the gateway
    ///      would silently accept this if `minAssetsOut` were ≤ the *gross* return value.
    function testFuzz_Redeem_RespectsNetMinAssetsOut(uint256 deposit) external {
        deposit = bound(deposit, 1e6, 500_000e6);

        vm.startPrank(users.alice);
        uint256 shares = feeVault.deposit(deposit, users.alice);

        uint256 net = feeVault.previewRedeem(shares); // net (post-fee)

        // Set minAssetsOut just above net: must revert with InsufficientAssetsOut(net, net+1).
        vm.expectRevert(abi.encodeWithSelector(Errors.Gateway__InsufficientAssetsOut.selector, net, net + 1));
        gateway.redeem(address(feeVault), shares, net + 1, users.alice, 0);

        // Same call with minAssetsOut at exactly net must succeed.
        gateway.redeem(address(feeVault), shares, net, users.alice, 0);
        vm.stopPrank();
    }

    /// @dev Cross-checks the gateway delivers exactly `net` assets (not gross). Confirms the bug is
    ///      reproduced by the mock — without the gateway fix, a user passing `minAssetsOut = gross`
    ///      would have it accepted but receive `gross - fee`.
    function testFuzz_Redeem_DeliversNetNotGross(uint256 deposit) external {
        deposit = bound(deposit, 1e6, 500_000e6);

        vm.startPrank(users.alice);
        uint256 shares = feeVault.deposit(deposit, users.alice);
        uint256 net = feeVault.previewRedeem(shares);

        uint256 usdcBefore = usdc.balanceOf(users.alice);
        gateway.redeem(address(feeVault), shares, net, users.alice, 0);
        uint256 received = usdc.balanceOf(users.alice) - usdcBefore;
        vm.stopPrank();

        assertEq(received, net, "alice receives net, not gross");
    }
}
