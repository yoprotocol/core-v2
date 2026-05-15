// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { YoERC4626Adapter } from "src/adapters/erc4626/YoERC4626Adapter.sol";
import { IYoERC4626VaultRegistry } from "src/interfaces/IYoERC4626VaultRegistry.sol";

import { Fork_Test } from "../Fork_Test.t.sol";

/// @dev Minimal real-USDC-backed 4626 deployed onto the fork. The adapter is asset-agnostic; we
///      don't need a specific upstream protocol (MetaMorpho / Aave / Yearn) to validate the
///      deposit/withdraw round-trip through real USDC (proxy + blacklist behavior).
contract ForkYieldVault is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Fork Yield USDC", "fyUSDC") { }
}

/// @notice End-to-end: real YoVault → YoERC4626Adapter → on-fork ERC-4626 holding real USDC.
contract ERC4626Fork_Test is Fork_Test {
    uint256 internal constant BASE_BLOCK = 0;

    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    uint256 internal constant DEPOSIT = 100_000e6;

    YoERC4626Adapter internal adapter;
    ForkYieldVault internal yieldVault;

    function setUp() public {
        _maybeSkip(_forkIfAvailable("BASE_RPC_URL", BASE_BLOCK), "BASE_RPC_URL");

        _deployStack(USDC, "Yo USDC Vault", "yoUSDC");

        adapter = new YoERC4626Adapter(IYoERC4626VaultRegistry(address(yieldVaultRegistry)), yoRegistry);
        yieldVault = new ForkYieldVault(USDC);
        vm.label(address(adapter), "YoERC4626Adapter");
        vm.label(address(yieldVault), "ForkYieldVault");

        vm.prank(users.owner);
        yieldVaultRegistry.setAllowed(address(yoVault), address(yieldVault), true);

        deal(address(USDC), address(yoVault), DEPOSIT);

        // Vault approves the adapter to pull USDC; the adapter manages its own approval to the
        // yield vault internally and resets it after each call.
        _vaultApprove(USDC, address(adapter), DEPOSIT);

        // Shares custody: the adapter calls `yieldVault.withdraw(...)` on behalf of the vault, so
        // the vault must approve the adapter on its 4626 shares.
        bytes memory approveSharesCall = abi.encodeCall(IERC20.approve, (address(adapter), type(uint256).max));
        _opManage(address(yieldVault), approveSharesCall);
    }

    function test_Fork_ERC4626_DepositWithdrawRoundTrip() external {
        uint256 vaultUsdcBefore = USDC.balanceOf(address(yoVault));

        // Deposit (assets → shares).
        bytes memory depositCall = abi.encodeCall(YoERC4626Adapter.deposit, (IERC4626(address(yieldVault)), DEPOSIT));
        _opManage(address(adapter), depositCall);

        assertEq(USDC.balanceOf(address(yoVault)), vaultUsdcBefore - DEPOSIT, "vault drained");
        assertGt(yieldVault.balanceOf(address(yoVault)), 0, "vault holds 4626 shares");

        // withdrawAll → recover all USDC.
        bytes memory withdrawCall = abi.encodeCall(YoERC4626Adapter.withdrawAll, (IERC4626(address(yieldVault))));
        _opManage(address(adapter), withdrawCall);

        assertEq(USDC.balanceOf(address(yoVault)), vaultUsdcBefore, "vault USDC restored");
        assertEq(yieldVault.balanceOf(address(yoVault)), 0, "shares burned");
    }

    function test_Fork_ERC4626_PartialWithdraw() external {
        bytes memory depositCall = abi.encodeCall(YoERC4626Adapter.deposit, (IERC4626(address(yieldVault)), DEPOSIT));
        _opManage(address(adapter), depositCall);

        uint256 part = DEPOSIT / 3;
        bytes memory withdrawCall = abi.encodeCall(YoERC4626Adapter.withdraw, (IERC4626(address(yieldVault)), part));
        _opManage(address(adapter), withdrawCall);

        assertEq(USDC.balanceOf(address(yoVault)), part, "got part USDC");
        assertGt(yieldVault.balanceOf(address(yoVault)), 0, "position not closed");
    }
}
