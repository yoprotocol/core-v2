// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { YoVault } from "../src/YoVault.sol";

import { BaseScript } from "./Base.s.sol";
import { ChainId } from "./ChainId.sol";

/// @notice Sets the test vault's withdrawal fee to match yoUSD Edge: 1e13 (0.001%) on the deposit
///         chains (Ethereum, Base, Arbitrum) and 0 on HyperEVM (execution-only, no deposits).
///         Owner-only (`updateWithdrawFee` passes `requiresAuth` for the owner); idempotent —
///         skips when the fee already matches.
///
///         Run once per chain:
///           forge script script/Update_WithdrawFee.s.sol:Update_WithdrawFee \
///               --rpc-url <mainnet|base|arbitrum|hyperliquid> -vvv --broadcast <signer flags>
///
///         Optional env vars:
///           - VAULT:              vault proxy to configure. Defaults to the yoTest vault.
///           - WITHDRAW_FEE:       fee as an 18-decimal fraction. Defaults to the chain's
///                                 yoUSD Edge value (1e13, or 0 on HyperEVM).
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}); must be the vault owner.
contract Update_WithdrawFee is BaseScript {
    error BroadcasterNotVaultOwner(address owner, address broadcaster);

    /// @dev The yoTest vault proxy (same address on every chain, cross-chain deterministic deploy).
    address internal constant DEFAULT_VAULT = 0xcF0fE5AB46cf260EB281650E8f999237684846AA;

    /// @dev yoUSD Edge's live withdrawal fee on the deposit chains: 0.001%.
    uint256 internal constant DEFAULT_FEE = 1e13;

    function run() public broadcast {
        YoVault vault = YoVault(payable(vm.envOr({ name: "VAULT", defaultValue: DEFAULT_VAULT })));
        uint256 chainDefault = chainId == ChainId.HYPEREVM ? 0 : DEFAULT_FEE;
        uint256 fee = vm.envOr({ name: "WITHDRAW_FEE", defaultValue: chainDefault });

        if (vault.owner() != broadcaster) {
            revert BroadcasterNotVaultOwner(vault.owner(), broadcaster);
        }

        uint256 current = vault.feeOnWithdraw();
        if (current == fee) {
            console2.log("feeOnWithdraw already %s - skipping", fee);
            return;
        }

        vault.updateWithdrawFee(fee);
        console2.log("feeOnWithdraw updated: %s -> %s", current, fee);
    }
}
