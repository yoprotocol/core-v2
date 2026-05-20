// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { YoIPORAdapter } from "src/adapters/ipor/YoIPORAdapter.sol";
import { IIPORPlasmaVault } from "src/interfaces/external/IIPORPlasmaVault.sol";
import { IYoERC4626VaultRegistry } from "src/interfaces/IYoERC4626VaultRegistry.sol";

import { Fork_Test } from "../Fork_Test.t.sol";

/// @notice End-to-end: real YoVault → YoIPORAdapter → real IPOR Fusion `PlasmaVault` on Base.
///         Guards the sync `IERC4626.deposit` leg against on-chain interface drift.
///
///         The async `redeemFromRequest` path is intentionally not exercised here: it requires the
///         IPOR alpha keeper to call `WithdrawManager.releaseFunds`, a permissioned step we can't
///         replay on a single-fork test. The signature itself is pinned at compile time via
///         `IIPORPlasmaVault`; any mismatch with a deployed PlasmaVault would surface as a selector
///         revert in production, which our concrete + invariant tests cover via the mock.
contract IPORFork_Test is Fork_Test {
    uint256 internal constant BASE_BLOCK = 0;

    /// @dev "IPOR USDC Base" lending-optimizer PlasmaVault — IPOR's flagship USDC vault on Base.
    ///      Update if the canonical deployment ever moves; the test's job is to fail loudly when
    ///      the deployed address stops behaving like an `IIPORPlasmaVault`.
    IIPORPlasmaVault internal constant PLASMA_VAULT = IIPORPlasmaVault(0x45aa96f0b3188D47a1DaFdbefCE1db6B37f58216);
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    /// @dev Resolved at fork time as `min(IDEAL_DEPOSIT, maxDeposit())`. IPOR PlasmaVaults often
    ///      cap deposits well below 100k USDC, so a fixed constant would brick this test on a
    ///      tight day.
    uint256 internal constant IDEAL_DEPOSIT = 100_000e6;

    uint256 internal depositAmount;
    YoIPORAdapter internal adapter;

    function setUp() public {
        _maybeSkip(_forkIfAvailable("base", BASE_BLOCK));

        // Sanity: confirm the pinned PlasmaVault still takes USDC. Fails noisily if IPOR ever
        // migrates this address to a different asset.
        assertEq(IERC4626(address(PLASMA_VAULT)).asset(), address(USDC), "PlasmaVault asset must be USDC");

        _deployStack(USDC, "Yo IPOR Vault", "yoIPOR");

        adapter = new YoIPORAdapter(IYoERC4626VaultRegistry(address(yieldVaultRegistry)), yoRegistry);
        vm.label(address(adapter), "YoIPORAdapter");
        vm.label(address(PLASMA_VAULT), "IPORPlasmaVault");

        vm.prank(users.owner);
        yieldVaultRegistry.setAllowed(address(yoVault), address(PLASMA_VAULT), true);

        // Cap deposit at 95% of live `maxDeposit` so the test rides under IPOR's current
        // ceiling. The 5% margin absorbs drift between setUp's read and the actual deposit
        // (TVL accrual shrinks the cap by a few wei per second on a busy vault).
        uint256 cap = IERC4626(address(PLASMA_VAULT)).maxDeposit(address(yoVault));
        if (cap == 0) {
            vm.skip(true, "IPOR PlasmaVault is full; skipping deposit fork test");
        }
        uint256 safeCap = (cap * 95) / 100;
        depositAmount = safeCap < IDEAL_DEPOSIT ? safeCap : IDEAL_DEPOSIT;

        // Fund the YoVault. `deal` works on standard ERC-20s; USDC on Base is FiatTokenV2_2 with
        // a regular `balances` mapping so this is fine.
        deal(address(USDC), address(yoVault), depositAmount);

        // Vault approves the adapter for the underlying token (deposit-leg approval).
        _vaultApprove(USDC, address(adapter), depositAmount);

        // Claim-leg approval: vault approves the adapter on the PlasmaVault's share token.
        // `redeemFromRequest` consumes via `_spendAllowance(owner, msg.sender, shares)`.
        bytes memory approveShares = abi.encodeCall(IERC20.approve, (address(adapter), type(uint256).max));
        _opManage(address(PLASMA_VAULT), approveShares);
    }

    /// @notice The sync deposit leg moves real USDC into the PlasmaVault and lands real shares on
    ///         the vault. Adapter ends clean (no balance, no allowance, no shares).
    function test_Fork_IPOR_Deposit() external {
        uint256 vaultAssetBefore = USDC.balanceOf(address(yoVault));
        uint256 vaultSharesBefore = IERC20(address(PLASMA_VAULT)).balanceOf(address(yoVault));

        bytes memory depositCall = abi.encodeCall(YoIPORAdapter.deposit, (PLASMA_VAULT, depositAmount));
        bytes memory ret = _opManage(address(adapter), depositCall);
        uint256 sharesReceived = abi.decode(ret, (uint256));

        assertGt(sharesReceived, 0, "got shares");
        assertEq(USDC.balanceOf(address(yoVault)), vaultAssetBefore - depositAmount, "asset pulled");
        assertEq(
            IERC20(address(PLASMA_VAULT)).balanceOf(address(yoVault)),
            vaultSharesBefore + sharesReceived,
            "shares credited"
        );

        // Adapter custody invariants: nothing left behind.
        assertEq(USDC.balanceOf(address(adapter)), 0, "adapter holds no asset");
        assertEq(IERC20(address(PLASMA_VAULT)).balanceOf(address(adapter)), 0, "adapter holds no shares");
        assertEq(USDC.allowance(address(adapter), address(PLASMA_VAULT)), 0, "no leftover allowance");
    }
}
