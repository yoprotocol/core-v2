// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { IYoPoolRegistry, PoolId } from "../src/interfaces/IYoPoolRegistry.sol";
import { YoPoolRegistry } from "../src/registries/YoPoolRegistry.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys the shared {YoPoolRegistry}, owned by the YO multisig, and — when
///         `OLD_POOL_REGISTRY` is set — migrates every pool of the current registry into it. This
///         is the per-chain registry of record for the pool whitelist (roster, governance
///         scalars, epoch); it does not gate execution, so it has no ordering dependency on the
///         adapters.
///
///         Migration copies each pool's stored config verbatim from the old registry. The
///         registry stores pool ids (hashes), not the `offchainId` strings `setPool` needs, so
///         the strings are pinned in {_offchainIds} (every id ever listed; extend it when a pool
///         is listed after this file was written). The script fails loud on any roster id
///         without a pinned string and asserts per-vault `poolCount` / `activePoolCount` parity
///         afterwards. Epochs restart at zero on the new instance; the re-emitted `PoolSet`
///         events give indexers the full roster of the new address.
///
///         Post-deploy operational steps (multisig, per vault + pool):
///           - `poolRegistry.setPool(vault, offchainId, config)` as the LAST call of each pool
///             onboarding batch (see {Configure_Pool}).
///           - Ownership transfer to the timelock is a follow-up operational step.
///
///         Optional env vars:
///           - YO_OWNER:           registry owner (defaults via {BaseScript-getYoOwner}).
///           - YO_GUARDIAN:        kill-switch guardian; defaults to the old registry's guardian
///                                 when migrating, else `address(0)` (disabled).
///           - YO_OPERATOR:        config operator; defaults to `address(0)` (disabled) until set
///                                 via `setOperator`.
///           - OLD_POOL_REGISTRY:  the registry to migrate from. The broadcaster must be the new
///                                 registry's owner — listing is owner-only.
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}).
contract Deploy_PoolRegistry is BaseScript {
    error RegistryOwnerMismatch(address owner, address broadcaster);
    error UnknownPoolId(address vault, PoolId id);
    error MigrationMismatch(address vault);

    /*//////////////////////////////////////////////////////////////////////////
                                       VAULTS
    //////////////////////////////////////////////////////////////////////////*/

    // The registry has no vault enumeration: the migration walks this pinned list.
    address internal constant YO_USD = 0x0000000f2eB9f69274678c76222B35eEc7588a65;
    address internal constant YO_ETH = 0x3A43AEC53490CB9Fa922847385D82fe25d0E9De7;
    address internal constant YO_USD_EDGE = 0x5DD8BFa6C5C68D05d25EF6143E05C11E26c4cDB7;
    address internal constant YO_EUR = 0x50c749aE210D3977ADC824AE11F3c7fd10c871e9;
    address internal constant YO_GOLD = 0x586675A3a46B008d8408933cf42d8ff6c9CC61a1;

    /// @dev `PoolId` preimages, built from {_offchainIds} at migration time.
    mapping(bytes32 id => string offchainId) private _offchainIdOf;

    function run() public broadcast returns (YoPoolRegistry poolRegistry) {
        address owner = getYoOwner();
        YoPoolRegistry old = YoPoolRegistry(vm.envOr({ name: "OLD_POOL_REGISTRY", defaultValue: address(0) }));
        address guardian = address(old) != address(0) ? old.guardian() : address(0);
        guardian = vm.envOr({ name: "YO_GUARDIAN", defaultValue: guardian });
        address operator = vm.envOr({ name: "YO_OPERATOR", defaultValue: address(0) });

        // Idempotent: a re-run (e.g. after the sequencer dropped part of the migration) reuses
        // the instance already at the CREATE2 address instead of colliding on it.
        address predicted = vm.computeCreate2Address(
            SALT, keccak256(abi.encodePacked(type(YoPoolRegistry).creationCode, abi.encode(owner, guardian, operator)))
        );
        if (predicted.code.length > 0) {
            poolRegistry = YoPoolRegistry(predicted);
            console2.log("=== YO Pool Registry Already Deployed ===");
        } else {
            poolRegistry = new YoPoolRegistry{ salt: SALT }(owner, guardian, operator);
            console2.log("=== YO Pool Registry Deployed ===");
        }

        console2.log("Chain ID:               ", chainId);
        console2.log("Version:                ", YO_VERSION);
        console2.log("Salt:                   ");
        console2.logBytes32(SALT);
        console2.log("");
        console2.log("YoPoolRegistry:         ", address(poolRegistry));
        console2.log("Owner:                  ", owner);
        console2.log("Guardian:               ", guardian);
        console2.log("Operator:               ", operator);

        if (address(old) != address(0)) {
            if (owner != broadcaster) {
                revert RegistryOwnerMismatch(owner, broadcaster);
            }
            _migrate(old, poolRegistry);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     MIGRATION
    //////////////////////////////////////////////////////////////////////////*/

    function _migrate(YoPoolRegistry old, YoPoolRegistry poolRegistry) private {
        string[] memory ids = _offchainIds();
        for (uint256 i = 0; i < ids.length; ++i) {
            _offchainIdOf[keccak256(bytes(ids[i]))] = ids[i];
        }

        console2.log("");
        console2.log("=== YO Pool Registry Migrated ===");
        console2.log("From:                   ", address(old));
        _migrateVault("yoUSD", YO_USD, old, poolRegistry);
        _migrateVault("yoETH", YO_ETH, old, poolRegistry);
        _migrateVault("yoUSD Edge", YO_USD_EDGE, old, poolRegistry);
        _migrateVault("yoEUR", YO_EUR, old, poolRegistry);
        _migrateVault("yoGOLD", YO_GOLD, old, poolRegistry);
    }

    function _migrateVault(string memory name, address vault, YoPoolRegistry old, YoPoolRegistry poolRegistry) private {
        IYoPoolRegistry.Pool[] memory list = old.pools(vault);
        uint256 copied;
        for (uint256 i = 0; i < list.length; ++i) {
            string memory offchainId = _offchainIdOf[PoolId.unwrap(list[i].id)];
            if (bytes(offchainId).length == 0) {
                revert UnknownPoolId(vault, list[i].id);
            }
            // Skip pools a previous run already copied verbatim, so a re-run sends only what is
            // missing.
            bytes memory current = abi.encode(poolRegistry.configOf(vault, list[i].id));
            if (keccak256(current) == keccak256(abi.encode(list[i].config))) {
                continue;
            }
            poolRegistry.setPool(vault, offchainId, list[i].config);
            ++copied;
        }

        if (
            poolRegistry.poolCount(vault) != old.poolCount(vault)
                || poolRegistry.activePoolCount(vault) != old.activePoolCount(vault)
        ) {
            revert MigrationMismatch(vault);
        }

        console2.log(name);
        console2.log("  copied:     ", copied);
        console2.log("  pools:      ", poolRegistry.poolCount(vault));
        console2.log("  active (N): ", poolRegistry.activePoolCount(vault));
    }

    /// @dev Every distinct `offchainId` listed on the current registry (`0x1c2dc9…` on Base): the
    ///      33 of {Seed_PoolRegistry} (`base:morpho:cbbtc-usdc` is shared by yoUSD and yoUSD
    ///      Edge) plus the two listed afterwards (`PoolSet` events, 2026-09).
    function _offchainIds() private pure returns (string[] memory ids) {
        ids = new string[](35);
        // yoUSD
        ids[0] = "ethereum:holding:usdt";
        ids[1] = "ethereum:morpho:cbbtc-usdc";
        ids[2] = "ethereum:morpho:wsteth-usdc";
        ids[3] = "ethereum:morpho:wsteth-usdt";
        ids[4] = "base:morpho:cbbtc-usdc"; // also yoUSD Edge
        ids[5] = "base:morpho:weth-usdc";
        ids[6] = "base:morpho:cbeth-usdc";
        ids[7] = "base:morpho:wsteth-usdc";
        // yoETH
        ids[8] = "ethereum:lido:steth";
        ids[9] = "ethereum:lido:wsteth";
        ids[10] = "ethereum:morpho:wsteth-weth";
        ids[11] = "base:morpho:wsteth-weth";
        ids[12] = "base:ipor:eth-lending-optimizer";
        // yoUSD Edge
        ids[13] = "base:morpho:cbxrp-usdc";
        ids[14] = "base:morpho:sol-usdc";
        ids[15] = "base:morpho:cbada-usdc";
        ids[16] = "base:morpho:cbdoge-usdc";
        ids[17] = "hyperevm:morpho:khype-usdc";
        ids[18] = "hyperevm:morpho:whype-usdc";
        ids[19] = "hyperevm:morpho:whype-usdc-77";
        ids[20] = "ethereum:morpho:pt-reusd-10dec2026-usdc";
        ids[21] = "ethereum:erc4626:aave-v4-usdg-core";
        ids[22] = "base:erc4626:clearstar-cbassets";
        ids[23] = "ethereum:holding:fxusd";
        ids[24] = "ethereum:holding:usdg";
        ids[25] = "ethereum:fxsave:fxsave";
        ids[26] = "base:morpho:cbxrp-usdc-62";
        ids[27] = "ethereum:aave:usdg_global_dollar_hub";
        // yoEUR
        ids[28] = "ethereum:morpho:wsteth-eurc";
        ids[29] = "base:morpho:wsteth-eurc";
        ids[30] = "base:morpho:cbeth-eurc";
        ids[31] = "base:morpho:weth-eurc";
        ids[32] = "base:morpho:cbbtc-eurc";
        ids[33] = "ethereum:erc4626:aave-v4-eurc-core";
        // yoGOLD
        ids[34] = "ethereum:ipor:fusion-alchemist";
    }
}
