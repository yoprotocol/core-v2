// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { YoFxSaveAdapter } from "src/adapters/fxsave/YoFxSaveAdapter.sol";
import { IFxUSDBasePool } from "src/interfaces/external/IFxUSDBasePool.sol";
import { ISavingFxUSD } from "src/interfaces/external/ISavingFxUSD.sol";
import { IYoFxSaveAdapter } from "src/interfaces/IYoFxSaveAdapter.sol";

import { Fork_Test } from "../Fork_Test.t.sol";

/// @dev Deposit entrypoint on `FxUSDBasePool`, used by the test to mint genuinely-backed fxSAVE
///      shares. Not part of the adapter's surface (the adapter only redeems).
interface IFxBasePoolDeposit {
    function deposit(
        address receiver,
        address tokenIn,
        uint256 amountTokenToDeposit,
        uint256 minSharesOut
    )
        external
        returns (uint256 amountSharesOut);
}

/// @notice End-to-end: real YoVault → YoFxSaveAdapter → real fxSAVE / FxUSDBasePool on Ethereum
///         mainnet. Covers both redemption modes (instant + cooldown) and the per-vault isolation
///         that protects the cooldown path.
contract FxSaveForkTest is Fork_Test {
    using SafeERC20 for IERC20;

    uint256 internal constant MAINNET_BLOCK = 0; // latest

    ISavingFxUSD internal constant FXSAVE = ISavingFxUSD(0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39);
    IERC20 internal constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    uint256 internal constant VAULT_USDC = 50_000e6;
    uint256 internal constant BOB_USDC = 30_000e6;

    YoFxSaveAdapter internal adapter;
    IFxUSDBasePool internal base;
    IERC20 internal fxUsd;

    function setUp() public {
        _maybeSkip(_forkIfAvailable("MAINNET_RPC_URL", MAINNET_BLOCK), "MAINNET_RPC_URL");

        _deployStack(USDC, "Yo fxSAVE Vault", "yoFXS");

        adapter = new YoFxSaveAdapter(FXSAVE, yoRegistry);
        base = adapter.base();
        fxUsd = adapter.fxUsd();

        vm.label(address(adapter), "YoFxSaveAdapter");
        vm.label(address(FXSAVE), "fxSAVE");
        vm.label(address(base), "FxUSDBasePool");
        vm.label(address(fxUsd), "fxUSD");
        vm.label(address(USDC), "USDC");

        // Give the vault genuinely-backed fxSAVE shares and let the adapter pull them.
        _mintFxSave(address(yoVault), VAULT_USDC);
        _vaultApprove(IERC20(address(FXSAVE)), address(adapter), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   INSTANT REDEEM
    //////////////////////////////////////////////////////////////////////////*/

    function test_Fork_FxSave_InstantRedeem() external {
        uint256 shares = FXSAVE.balanceOf(address(yoVault));
        assertGt(shares, 0, "no fxSAVE shares minted");

        // Fee-free reference: fxSAVE shares → base shares → pro-rata fxUSD/USDC.
        uint256 baseAssets = FXSAVE.previewRedeem(shares);
        (uint256 yieldNoFee, uint256 stableNoFee) = base.previewRedeem(baseAssets);

        bytes memory call = abi.encodeCall(YoFxSaveAdapter.instantRedeem, (shares));
        (uint256 fxUsdOut, uint256 usdcOut) = abi.decode(_opManage(address(adapter), call), (uint256, uint256));

        assertGt(fxUsdOut, 0, "no fxUSD out");
        assertGt(usdcOut, 0, "no USDC out");
        // Instant path charges a fee, so outputs never exceed the fee-free preview.
        assertLe(fxUsdOut, yieldNoFee, "fxUSD exceeds no-fee preview");
        assertLe(usdcOut, stableNoFee, "USDC exceeds no-fee preview");

        assertEq(FXSAVE.balanceOf(address(yoVault)), 0, "fxSAVE not fully redeemed");
        assertEq(fxUsd.balanceOf(address(yoVault)), fxUsdOut, "vault fxUSD mismatch");
        assertEq(USDC.balanceOf(address(yoVault)), usdcOut, "vault USDC mismatch");
        // Adapter retains nothing.
        assertEq(fxUsd.balanceOf(address(adapter)), 0, "adapter leaked fxUSD");
        assertEq(USDC.balanceOf(address(adapter)), 0, "adapter leaked USDC");
        assertEq(base.balanceOf(address(adapter)), 0, "adapter leaked base shares");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  COOLDOWN ROUNDTRIP
    //////////////////////////////////////////////////////////////////////////*/

    function test_Fork_FxSave_CooldownRoundTrip() external {
        uint256 shares = FXSAVE.balanceOf(address(yoVault));

        bytes memory requestCall = abi.encodeCall(YoFxSaveAdapter.requestRedeem, (shares));
        uint256 assets = abi.decode(_opManage(address(adapter), requestCall), (uint256));
        assertGt(assets, 0, "no base shares locked");
        assertEq(FXSAVE.balanceOf(address(yoVault)), 0, "fxSAVE not pulled");

        bytes memory claimCall = abi.encodeCall(YoFxSaveAdapter.claim, ());

        // Claiming before the cooldown elapses must revert (fx base pool locks the shares).
        authority.setAllowed(users.operator, address(adapter), YoFxSaveAdapter.claim.selector, true);
        vm.prank(users.operator);
        vm.expectRevert();
        yoVault.manage(address(adapter), claimCall, 0);

        // Warp past the cooldown and claim for real.
        vm.warp(block.timestamp + base.redeemCoolDownPeriod() + 1);

        (uint256 yieldExpected, uint256 stableExpected) = base.previewRedeem(assets);
        (uint256 fxUsdOut, uint256 usdcOut) = abi.decode(_opManage(address(adapter), claimCall), (uint256, uint256));

        assertGt(fxUsdOut, 0, "no fxUSD claimed");
        assertGt(usdcOut, 0, "no USDC claimed");
        // Cooldown path is fee-free: payout matches the base pool preview within rounding.
        assertApproxEqRel(fxUsdOut, yieldExpected, 1e15, "fxUSD off preview");
        assertApproxEqRel(usdcOut, stableExpected, 1e15, "USDC off preview");
        assertEq(fxUsd.balanceOf(address(yoVault)), fxUsdOut, "vault fxUSD mismatch");
        assertEq(USDC.balanceOf(address(yoVault)), usdcOut, "vault USDC mismatch");
    }

    function test_Fork_FxSave_ClaimNoPosition() external {
        bytes memory claimCall = abi.encodeCall(YoFxSaveAdapter.claim, ());
        authority.setAllowed(users.operator, address(adapter), YoFxSaveAdapter.claim.selector, true);
        vm.prank(users.operator);
        vm.expectRevert(IYoFxSaveAdapter.NoPosition.selector);
        yoVault.manage(address(adapter), claimCall, 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PER-VAULT ISOLATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Two distinct callers (the vault and an independent account) each request a cooldown
    ///      redemption, then claim. Each receives exactly its own position's worth — proving the
    ///      per-vault redeemer prevents one caller from draining another's locked funds.
    function test_Fork_FxSave_PerCallerIsolation() external {
        uint256 sharesVault = FXSAVE.balanceOf(address(yoVault));

        address bob = users.alice;
        _mintFxSave(bob, BOB_USDC);
        uint256 sharesBob = FXSAVE.balanceOf(bob);

        // Vault requests via the manage path.
        bytes memory requestCall = abi.encodeCall(YoFxSaveAdapter.requestRedeem, (sharesVault));
        uint256 assetsVault = abi.decode(_opManage(address(adapter), requestCall), (uint256));

        // Bob requests by calling the adapter directly (no vault, no registry gate by design).
        vm.startPrank(bob);
        IERC20(address(FXSAVE)).forceApprove(address(adapter), sharesBob);
        uint256 assetsBob = adapter.requestRedeem(sharesBob);
        vm.stopPrank();

        assertTrue(adapter.redeemerOf(address(yoVault)) != adapter.redeemerOf(bob), "redeemers not isolated");

        vm.warp(block.timestamp + base.redeemCoolDownPeriod() + 1);

        (uint256 yieldVaultExp,) = base.previewRedeem(assetsVault);
        (uint256 yieldBobExp,) = base.previewRedeem(assetsBob);

        bytes memory claimCall = abi.encodeCall(YoFxSaveAdapter.claim, ());
        (uint256 fxUsdVault,) = abi.decode(_opManage(address(adapter), claimCall), (uint256, uint256));

        vm.prank(bob);
        (uint256 fxUsdBob,) = adapter.claim();

        // Each caller got its own position only — not the other's. If positions had commingled, the
        // first claimer would have drained both.
        assertApproxEqRel(fxUsdVault, yieldVaultExp, 1e15, "vault did not get its own share");
        assertApproxEqRel(fxUsdBob, yieldBobExp, 1e15, "bob did not get its own share");
        assertEq(fxUsd.balanceOf(bob), fxUsdBob, "bob fxUSD mismatch");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                       HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Mint genuinely-backed fxSAVE shares to `to` via USDC → base pool → fxSAVE. `deal`-ing
    ///      fxSAVE shares directly would desync the vault's backing and break redemptions.
    function _mintFxSave(address to, uint256 usdcAmount) internal returns (uint256 shares) {
        deal(address(USDC), address(this), usdcAmount);
        USDC.forceApprove(address(base), usdcAmount);
        uint256 baseShares = IFxBasePoolDeposit(address(base)).deposit(address(this), address(USDC), usdcAmount, 0);

        IERC20(address(base)).forceApprove(address(FXSAVE), baseShares);
        shares = FXSAVE.deposit(baseShares, to);
    }
}
