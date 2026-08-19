// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { YoVaultBase_Test } from "../../concrete/yo-vault/YoVaultBase.t.sol";

contract DepositRedeemYoVaultIntegrationFuzzTest is YoVaultBase_Test {
    using Math for uint256;

    /// @dev Any deposit at parity oracle and no fees mints exactly `assets` shares.
    function testFuzz_Deposit_NoFees_OneToOne(uint256 assets) external {
        assets = bound(assets, 1, 500_000e6);
        vm.prank(users.alice);
        yoVault.deposit(assets, users.alice);
        assertEq(yoVault.balanceOf(users.alice), assets);
    }

    /// @dev Instant redeem round-trip: deposit assets, redeem all shares, recover all assets
    ///      (no fees, parity oracle).
    function testFuzz_DepositRedeem_RoundTrip(uint256 assets) external {
        assets = bound(assets, 1, 500_000e6);

        uint256 aliceUsdcBefore = usdc.balanceOf(users.alice);
        vm.prank(users.alice);
        yoVault.deposit(assets, users.alice);

        uint256 shares = yoVault.balanceOf(users.alice);
        vm.prank(users.alice);
        yoVault.redeem(shares, users.alice, users.alice);

        assertEq(yoVault.balanceOf(users.alice), 0, "shares burned");
        assertEq(usdc.balanceOf(users.alice), aliceUsdcBefore, "round trip preserves USDC");
    }

    /// @dev `totalAssets()` scales linearly with the mocked oracle price.
    function testFuzz_TotalAssets_LinearInOraclePrice(uint256 assets, uint256 price) external {
        assets = bound(assets, 1, 500_000e6);
        // USDC has 6 decimals; oracle returns 6-decimal price. Keep prices in a sane band.
        price = bound(price, 1, 1e12);

        vm.prank(users.alice);
        yoVault.deposit(assets, users.alice);

        _setOraclePrice(price);

        uint256 supply = yoVault.totalSupply();
        uint256 expected = price.mulDiv(supply, 10 ** yoVault.decimals(), Math.Rounding.Floor);
        assertEq(yoVault.totalAssets(), expected);
    }
}
