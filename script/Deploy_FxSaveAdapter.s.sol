// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { YoFxSaveAdapter } from "../src/adapters/fxsave/YoFxSaveAdapter.sol";
import { ISavingFxUSD } from "../src/interfaces/external/ISavingFxUSD.sol";
import { IYoRegistry } from "../src/interfaces/IYoRegistry.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys the immutable {YoFxSaveAdapter} bound to fx Protocol's fxSAVE (`SavingFxUSD`).
///         Mainnet-only — fx Protocol is not deployed on L2s, and {BaseScript-getFxSave} reverts on
///         any other chain.
///
///         The adapter is redemption-only (instant + cooldown); deposits into fxSAVE flow through
///         the swap adapter. The constructor derives and pins `base` / `fxUSD` / `USDC` from the
///         live fxSAVE contract, so the deploy transaction itself validates the integration wiring.
///
///         Per-vault {YoFxSaveRedeemer} shims are NOT deployed here — the adapter deploys them
///         lazily (CREATE2, salt = vault) on each vault's first `requestRedeem`.
///
///         Post-deploy operational steps (multisig, per vault):
///           - `approvalRegistry.setApproval(vault, fxSave, adapter, cap)` then
///             `vault.approveToken(fxSave, adapter, cap)` — covers both redeem entrypoints.
///           - Grant the operator the adapter selectors on the vault's authority.
///
///         Required env vars:
///           - YO_REGISTRY:        live YoRegistry proxy on the target chain (adapter `rescue` auth).
///         Optional env vars:
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}).
contract Deploy_FxSaveAdapter is BaseScript {
    error FxSaveNotDeployed(uint256 chainId, address fxSave);

    function run() public broadcast returns (YoFxSaveAdapter adapter) {
        IYoRegistry yoRegistry = IYoRegistry(getYoRegistry());

        address fxSave = getFxSave();
        if (fxSave.code.length == 0) {
            revert FxSaveNotDeployed(chainId, fxSave);
        }

        adapter = new YoFxSaveAdapter{ salt: SALT }(ISavingFxUSD(fxSave), yoRegistry);

        _log(adapter, address(yoRegistry));
    }

    function _log(YoFxSaveAdapter adapter, address yoRegistry) internal view {
        console2.log("=== YO fxSAVE Adapter Deployed ===");
        console2.log("Chain ID:             ", chainId);
        console2.log("Version:              ", YO_VERSION);
        console2.log("Salt:                 ");
        console2.logBytes32(SALT);
        console2.log("");
        console2.log("YoFxSaveAdapter:      ", address(adapter));
        console2.log("fxSAVE (SavingFxUSD): ", address(adapter.fxSave()));
        console2.log("FxUSDBasePool:        ", address(adapter.base()));
        console2.log("fxUSD (yield leg):    ", address(adapter.fxUsd()));
        console2.log("USDC (stable leg):    ", address(adapter.usdc()));
        console2.log("YoRegistry (existing):", yoRegistry);
    }
}

