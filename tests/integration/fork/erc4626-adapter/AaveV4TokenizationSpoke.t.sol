// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoERC4626Adapter } from "src/adapters/erc4626/YoERC4626Adapter.sol";
import { IYoERC4626VaultRegistry } from "src/interfaces/IYoERC4626VaultRegistry.sol";

import { Fork_Test } from "../Fork_Test.t.sol";

/// @notice End-to-end: real YoVault → YoERC4626Adapter → live Aave v4 USDC Tokenization Spoke
///         (Core hub) on Ethereum mainnet.
///
///         Aave v4 restricts acting on someone else's spoke position to governance-activated
///         position managers, so YO integrates through Aave's Tokenization Spokes instead: official
///         ERC-4626 wrappers (`ITokenizationSpoke is IERC4626`) whose deposit/withdraw/redeem are
///         permissionless. The YO vault holds the ERC-4626 shares directly — the position stays
///         inside the vault — and no Aave-specific adapter or governance action is needed.
contract AaveV4TokenizationSpokeForkTest is Fork_Test {
    uint256 internal constant MAINNET_BLOCK = 0; // latest

    /// @dev `AaveV4EthereumTokenizationSpokes.CORE_USDC_TOKENIZATION_SPOKE` from
    ///      bgd-labs/aave-address-book.
    IERC4626 internal constant WA_USDC = IERC4626(0x531E90a2376902DE8915789Fcc1075e3B0c153E7);
    IERC20 internal constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    /// @dev Kept small so the test stays comfortably under the Core hub's conservative supply caps.
    uint256 internal constant VAULT_USDC = 10_000e6;
    uint256 internal constant DEPOSIT = 2000e6;

    YoERC4626Adapter internal adapter;

    function setUp() public {
        _maybeSkip(_forkIfAvailable("MAINNET_RPC_URL", MAINNET_BLOCK), "MAINNET_RPC_URL");

        _deployStack(USDC, "Yo USDC Vault", "yoUSDC");

        adapter = new YoERC4626Adapter(IYoERC4626VaultRegistry(address(yieldVaultRegistry)), yoRegistry);
        vm.label(address(adapter), "YoERC4626Adapter");
        vm.label(address(WA_USDC), "CoreUsdcTokenizationSpoke");
        vm.label(address(USDC), "USDC");

        // Integration sanity: the tokenization spoke is an ERC-4626 over USDC.
        assertEq(WA_USDC.asset(), address(USDC), "unexpected underlying");

        vm.prank(users.owner);
        yieldVaultRegistry.setAllowed(address(yoVault), address(WA_USDC), true);

        deal(address(USDC), address(yoVault), VAULT_USDC);

        // Vault approves the adapter to pull USDC; the adapter manages its own approval to the
        // tokenization spoke internally and resets it after each call.
        _vaultApprove(USDC, address(adapter), type(uint256).max);

        // Shares custody: the adapter calls `WA_USDC.withdraw/redeem(...)` with the vault as owner,
        // so the vault must approve the adapter on its 4626 shares.
        bytes memory approveSharesCall = abi.encodeCall(IERC20.approve, (address(adapter), type(uint256).max));
        _opManage(address(WA_USDC), approveSharesCall);
    }

    function test_Fork_AaveV4TokenizationSpoke_DepositWithdrawRoundTrip() external {
        // ------------------------------- Deposit -------------------------------
        bytes memory depositCall = abi.encodeCall(YoERC4626Adapter.deposit, (WA_USDC, DEPOSIT));
        uint256 sharesReceived = abi.decode(_opManage(address(adapter), depositCall), (uint256));

        assertGt(sharesReceived, 0, "no shares received");
        // Position sits inside the vault as ERC-4626 shares.
        assertEq(WA_USDC.balanceOf(address(yoVault)), sharesReceived, "vault holds the shares");
        assertEq(USDC.balanceOf(address(yoVault)), VAULT_USDC - DEPOSIT, "vault USDC after deposit");
        assertApproxEqRel(WA_USDC.previewRedeem(sharesReceived), DEPOSIT, 1e15, "share value after deposit");
        // Custody invariants: adapter ends clean.
        assertEq(USDC.balanceOf(address(adapter)), 0, "adapter USDC after deposit");
        assertEq(WA_USDC.balanceOf(address(adapter)), 0, "adapter shares after deposit");
        assertEq(USDC.allowance(address(adapter), address(WA_USDC)), 0, "adapter allowance after deposit");

        // --------------------------- Partial withdraw ---------------------------
        uint256 part = DEPOSIT / 3;
        bytes memory withdrawCall = abi.encodeCall(YoERC4626Adapter.withdraw, (WA_USDC, part));
        _opManage(address(adapter), withdrawCall);

        assertEq(USDC.balanceOf(address(yoVault)), VAULT_USDC - DEPOSIT + part, "vault USDC after withdraw");
        assertGt(WA_USDC.balanceOf(address(yoVault)), 0, "position not closed");

        // ------------------------------ WithdrawAll ------------------------------
        bytes memory withdrawAllCall = abi.encodeCall(YoERC4626Adapter.withdrawAll, (WA_USDC));
        uint256 assetsReceived = abi.decode(_opManage(address(adapter), withdrawAllCall), (uint256));

        assertGt(assetsReceived, 0, "nothing redeemed");
        assertEq(WA_USDC.balanceOf(address(yoVault)), 0, "shares not fully burned");
        // Same-block round trip: only ERC-4626 floor-rounding dust may be lost.
        assertApproxEqAbs(USDC.balanceOf(address(yoVault)), VAULT_USDC, 2, "vault USDC after full exit");
        assertEq(USDC.balanceOf(address(adapter)), 0, "adapter USDC after full exit");
    }
}
