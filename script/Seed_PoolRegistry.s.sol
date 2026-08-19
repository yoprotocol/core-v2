// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { IYoPoolRegistry } from "../src/interfaces/IYoPoolRegistry.sol";
import { YoPoolRegistry } from "../src/registries/YoPoolRegistry.sol";

import { BaseScript } from "./Base.s.sol";
import { ChainId } from "./ChainId.sol";

/// @notice Seeds the {YoPoolRegistry} on the governance chain (Base) with the whitelist migrated
///         from the yo-backend `Pool` collection (export of 2026-08, 34 pools across five vaults).
///         `setPool` is an upsert, so re-running is safe — it rewrites configs and bumps epochs.
///
///         Mapping decisions (locked with governance):
///           - `offchainId` scheme is `network:kind:slug` (e.g. `ethereum:morpho:cbbtc-usdc`);
///             these strings are the permanent pool identities.
///           - `adapter` records the deployed Yo adapter for the pool's venue kind on its
///             EXECUTION network, pinned inline below (mirrors the backend's
///             `YO_ADAPTER_ADDRESSES` config). Most adapters are CREATE2-deterministic and share
///             one address across chains; HyperEVM's Morpho adapter diverged.
///           - USDT, fxUSD, USDG, and fxSAVE are carried holdings: `ACTIVE` + `idleOnly`
///             (excluded from the cap denominator N). "Lido stETH Arb" (the withdrawal-queue
///             position) is deliberately NOT migrated.
///           - `riskScore` comes from the backend's 0-100 score (idle holdings default to 0);
///             `elasticityWad`/`exitLatencySeconds` are copied where present, else zero.
///
///         Required env vars:
///           - POOL_REGISTRY:      the {YoPoolRegistry} instance on Base.
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}); must be the registry
///                                 owner.
contract Seed_PoolRegistry is BaseScript {
    error RegistryOwnerMismatch(address owner, address broadcaster);

    /*//////////////////////////////////////////////////////////////////////////
                                       VAULTS
    //////////////////////////////////////////////////////////////////////////*/

    address internal constant YO_USD = 0x0000000f2eB9f69274678c76222B35eEc7588a65;
    address internal constant YO_ETH = 0x3A43AEC53490CB9Fa922847385D82fe25d0E9De7;
    address internal constant YO_USD_EDGE = 0x5DD8BFa6C5C68D05d25EF6143E05C11E26c4cDB7;
    address internal constant YO_EUR = 0x50c749aE210D3977ADC824AE11F3c7fd10c871e9;
    address internal constant YO_GOLD = 0x586675A3a46B008d8408933cf42d8ff6c9CC61a1;

    /*//////////////////////////////////////////////////////////////////////////
                                     VENUE KINDS
    //////////////////////////////////////////////////////////////////////////*/

    // Non-canonical copies of the off-chain venue-kind table (the registry validates only
    // non-zero). Keep in sync with the decision layer and {Configure_Pool}.
    uint8 internal constant VENUE_KIND_ERC4626 = 1;
    uint8 internal constant VENUE_KIND_MORPHO_MARKET = 2;
    uint8 internal constant VENUE_KIND_LIDO = 3;
    uint8 internal constant VENUE_KIND_IPOR = 4;
    uint8 internal constant VENUE_KIND_FXSAVE = 5;
    uint8 internal constant VENUE_KIND_HOLDING = 6;

    /*//////////////////////////////////////////////////////////////////////////
                                  EXECUTION CHAINS
    //////////////////////////////////////////////////////////////////////////*/

    uint64 internal constant ETHEREUM = uint64(ChainId.ETHEREUM);
    uint64 internal constant BASE = uint64(ChainId.BASE);
    uint64 internal constant HYPEREVM = uint64(ChainId.HYPEREVM);

    /*//////////////////////////////////////////////////////////////////////////
                                     YO ADAPTERS
    //////////////////////////////////////////////////////////////////////////*/

    // Deployed Yo adapters per venue kind (backend `YO_ADAPTER_ADDRESSES`). CREATE2-deterministic
    // instances share one address on Ethereum, Base, and HyperEVM; exceptions are pinned per
    // chain. Code presence verified on every (adapter, chain) pair recorded below (2026-08-04).
    address internal constant ERC4626_ADAPTER = 0x206fF3F58F57d00c48aF6010De6dC26f913eFd64;
    address internal constant MORPHO_ADAPTER = 0x93A3A3325dE6aB429523D144b41A032e7D7456Ab;
    address internal constant MORPHO_ADAPTER_HYPEREVM = 0x946FD049C47BeFF53a32588C67df6a5A16B805F0;
    address internal constant IPOR_ADAPTER = 0x4409446B49E24861697d566e5c6D68C0d8F3C50f;
    address internal constant LIDO_ADAPTER = 0xF837334c5c48F16A8A73aFFb09859Bb7FDB467E0;
    address internal constant FXSAVE_ADAPTER = 0xfaeeA990Cb042B5597AC2c497DBDf56C091180DF;

    /// @dev The live YoVaultTransfer divest adapter recorded for the yoUSD USDT holding (the one
    ///      adapter address the backend export does carry).
    address internal constant USDT_TRANSFER_ADAPTER = 0xa48079728F1E18D095BD9DAFDcBcd28CE9E3d136;

    YoPoolRegistry internal registry;

    function run() public broadcast {
        if (chainId != ChainId.BASE) {
            revert ChainNotSupported("Seed_PoolRegistry", chainId);
        }

        registry = YoPoolRegistry(vm.envAddress("POOL_REGISTRY"));
        if (registry.owner() != broadcaster) {
            revert RegistryOwnerMismatch(registry.owner(), broadcaster);
        }

        _seedYoUsd();
        _seedYoEth();
        _seedYoUsdEdge();
        _seedYoEur();
        _seedYoGold();

        console2.log("=== YO Pool Registry Seeded ===");
        _logVault("yoUSD", YO_USD);
        _logVault("yoETH", YO_ETH);
        _logVault("yoUSD Edge", YO_USD_EDGE);
        _logVault("yoEUR", YO_EUR);
        _logVault("yoGOLD", YO_GOLD);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   VAULT ROSTERS
    //////////////////////////////////////////////////////////////////////////*/

    function _seedYoUsd() private {
        _holding(
            YO_USD,
            "ethereum:holding:usdt",
            ETHEREUM,
            USDT_TRANSFER_ADAPTER,
            0xdAC17F958D2ee523a2206206994597C13D831ec7,
            0
        );
        _morpho(
            YO_USD,
            "ethereum:morpho:cbbtc-usdc",
            ETHEREUM,
            0x64d65c9a2d91c36d56fbc42d69e979335320169b3df63bf92789e2c8883fcc64,
            93
        );
        _morpho(
            YO_USD,
            "ethereum:morpho:wsteth-usdc",
            ETHEREUM,
            0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc,
            97
        );
        _morpho(
            YO_USD,
            "ethereum:morpho:wsteth-usdt",
            ETHEREUM,
            0xe7e9694b754c4d4f7e21faf7223f6fa71abaeb10296a4c43a54a7977149687d2,
            97
        );
        _morpho(
            YO_USD,
            "base:morpho:cbbtc-usdc",
            BASE,
            0x9103c3b4e834476c9a62ea009ba2c884ee42e94e6e314a26f04d312434191836,
            92
        );
        _morpho(
            YO_USD,
            "base:morpho:weth-usdc",
            BASE,
            0x8793cf302b8ffd655ab97bd1c695dbd967807e8367a65cb2f4edaf1380ba1bda,
            98
        );
        _morpho(
            YO_USD,
            "base:morpho:cbeth-usdc",
            BASE,
            0x1c21c59df9db44bf6f645d854ee710a8ca17b479451447e9f56758aee10a2fad,
            96
        );
        _morpho(
            YO_USD,
            "base:morpho:wsteth-usdc",
            BASE,
            0x13c42741a359ac4a8aa8287d2be109dcf28344484f91185f9a79bd5a805a55ae,
            97
        );
    }

    function _seedYoEth() private {
        _venue(
            YO_ETH,
            "ethereum:lido:steth",
            VENUE_KIND_LIDO,
            ETHEREUM,
            0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84,
            100,
            0,
            259_200
        );
        _venue(
            YO_ETH,
            "ethereum:lido:wsteth",
            VENUE_KIND_LIDO,
            ETHEREUM,
            0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0,
            98,
            0,
            0
        );
        _morpho(
            YO_ETH,
            "ethereum:morpho:wsteth-weth",
            ETHEREUM,
            0xb8fc70e82bc5bb53e773626fcc6a23f7eefa036918d7ef216ecfb1950a94a85e,
            94
        );
        _morpho(
            YO_ETH,
            "base:morpho:wsteth-weth",
            BASE,
            0x3a4048c64ba1b375330d376b1ce40e4047d03b47ab4d48af484edec9fec801ba,
            93
        );
        _venue(
            YO_ETH,
            "base:ipor:eth-lending-optimizer",
            VENUE_KIND_IPOR,
            BASE,
            0x17d0f109EE895bAD0b68AA104AA72bd0b003AD8E,
            100,
            0.25e18,
            0
        );
    }

    function _seedYoUsdEdge() private {
        _morpho(
            YO_USD_EDGE,
            "base:morpho:cbxrp-usdc",
            BASE,
            0xfdfecf85a4dd90a7637ae2aaf28b35061166f0e62bfc714c565eed9f7e959783,
            92
        );
        _morpho(
            YO_USD_EDGE,
            "base:morpho:cbbtc-usdc",
            BASE,
            0x9103c3b4e834476c9a62ea009ba2c884ee42e94e6e314a26f04d312434191836,
            92
        );
        _morpho(
            YO_USD_EDGE,
            "base:morpho:sol-usdc",
            BASE,
            0x7dc02ff6c536b1d49d7fba770438d79f5bd1f1c78884629b7d1aaee19675782b,
            92
        );
        _morpho(
            YO_USD_EDGE,
            "base:morpho:cbada-usdc",
            BASE,
            0xd7520ad198b497b6eb75bc690268f4597630dbc12e305e9d4105843bab36e41d,
            92
        );
        _morpho(
            YO_USD_EDGE,
            "base:morpho:cbdoge-usdc",
            BASE,
            0x73527ddd796e6d4f48387adaae36f6f3d49d606d7f2a15eb0c931416a58875d8,
            92
        );
        _morpho(
            YO_USD_EDGE,
            "hyperevm:morpho:khype-usdc",
            HYPEREVM,
            0xe7aa046832007a975d4619260d221229e99cc27da2e6ef162881202b4cd2349b,
            95
        );
        _morpho(
            YO_USD_EDGE,
            "hyperevm:morpho:whype-usdc",
            HYPEREVM,
            0xd13b1bad542045a8dc729fa0ffcc4f538b9771592c2666e1f09667dcf85804fc,
            95
        );
        _morpho(
            YO_USD_EDGE,
            "hyperevm:morpho:whype-usdc-77",
            HYPEREVM,
            0xd7d38220652d19c87099c3b23de9a70a1893620a050c635d1a94bd947c9c59a8,
            91
        );
        _morpho(
            YO_USD_EDGE,
            "ethereum:morpho:pt-reusd-10dec2026-usdc",
            ETHEREUM,
            0x1e9d614631a7df0ec07fb05b2c8cb2491575fd1a63a33bf187a6afb295a4fc64,
            84
        );
        _venue(
            YO_USD_EDGE,
            "ethereum:erc4626:aave-v4-usdg-core",
            VENUE_KIND_ERC4626,
            ETHEREUM,
            0xAC2435E3C25e8246870D33ce0a26988A46d5DB68,
            94,
            0.25e18,
            0
        );
        _venue(
            YO_USD_EDGE,
            "base:erc4626:clearstar-cbassets",
            VENUE_KIND_ERC4626,
            BASE,
            0x91C056B6d4311a743614FBc03ac32d4E6A2d3a3c,
            91,
            0.25e18,
            0
        );
        _holding(
            YO_USD_EDGE, "ethereum:holding:fxusd", ETHEREUM, address(0), 0x085780639CC2cACd35E474e71f4d000e2405d8f6, 0
        );
        _holding(
            YO_USD_EDGE, "ethereum:holding:usdg", ETHEREUM, address(0), 0xe343167631d89B6Ffc58B88d6b7fB0228795491D, 0
        );
        // fxSAVE is a real venue (kind FXSAVE) but currently a carried holding: idleOnly per
        // governance decision, so it keeps its venue identity without occupying a whitelist slot.
        _holdingOfKind(
            YO_USD_EDGE,
            "ethereum:fxsave:fxsave",
            VENUE_KIND_FXSAVE,
            ETHEREUM,
            0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39,
            95
        );
    }

    function _seedYoEur() private {
        _morpho(
            YO_EUR,
            "ethereum:morpho:wsteth-eurc",
            ETHEREUM,
            0x7421c2741e064e8c53fcb5de9faf7f0025dce75bc1caf26774dd878291c81dac,
            97
        );
        _morpho(
            YO_EUR,
            "base:morpho:wsteth-eurc",
            BASE,
            0xf7e40290f8ca1d5848b3c129502599aa0f0602eb5f5235218797a34242719561,
            96
        );
        _morpho(
            YO_EUR,
            "base:morpho:cbeth-eurc",
            BASE,
            0x7fc498ddcb7707d6f85f6dc81f61edb6dc8d7f1b47a83b55808904790564929a,
            96
        );
        _morpho(
            YO_EUR,
            "base:morpho:weth-eurc",
            BASE,
            0xa9b5142fa687a24c275faf731f13b52faa9873252bb4e1cb6077aa1f412edb0b,
            98
        );
        _morpho(
            YO_EUR,
            "base:morpho:cbbtc-eurc",
            BASE,
            0x67ebd84b2fb39e3bc5a13d97e4c07abe1ea617e40654826e9abce252e95f049e,
            97
        );
        _venue(
            YO_EUR,
            "ethereum:erc4626:aave-v4-eurc-core",
            VENUE_KIND_ERC4626,
            ETHEREUM,
            0x6D9e2Cdd61CaF69af99b275704B6e272C41c6718,
            94,
            0.25e18,
            0
        );
    }

    function _seedYoGold() private {
        _venue(
            YO_GOLD,
            "ethereum:ipor:fusion-alchemist",
            VENUE_KIND_IPOR,
            ETHEREUM,
            0x87428d886F43068A44d7bDEeF106D3c42E1d6f23,
            99,
            0.25e18,
            259_200
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev An allocatable Morpho market: `venueKey` is the market id.
    function _morpho(
        address vault,
        string memory offchainId,
        uint64 poolChainId,
        bytes32 marketId,
        uint8 riskScore
    )
        private
    {
        registry.setPool(
            vault,
            offchainId,
            IYoPoolRegistry.PoolConfig({
                status: IYoPoolRegistry.PoolStatus.ACTIVE,
                venueKind: VENUE_KIND_MORPHO_MARKET,
                idleOnly: false,
                riskScore: riskScore,
                exitLatencySeconds: 0,
                elasticityWad: 0,
                entrySlippageWad: 0,
                exitCostWad: 0,
                chainId: poolChainId,
                adapter: _adapterFor(VENUE_KIND_MORPHO_MARKET, poolChainId),
                venueKey: marketId,
                metadataHash: 0
            })
        );
    }

    /// @dev An allocatable address-keyed venue (ERC-4626 vault, Lido, IPOR plasma vault).
    function _venue(
        address vault,
        string memory offchainId,
        uint8 venueKind,
        uint64 poolChainId,
        address venueAddress,
        uint8 riskScore,
        uint64 elasticityWad,
        uint32 exitLatencySeconds
    )
        private
    {
        registry.setPool(
            vault,
            offchainId,
            IYoPoolRegistry.PoolConfig({
                status: IYoPoolRegistry.PoolStatus.ACTIVE,
                venueKind: venueKind,
                idleOnly: false,
                riskScore: riskScore,
                exitLatencySeconds: exitLatencySeconds,
                elasticityWad: elasticityWad,
                entrySlippageWad: 0,
                exitCostWad: 0,
                chainId: poolChainId,
                adapter: _adapterFor(venueKind, poolChainId),
                venueKey: bytes32(uint256(uint160(venueAddress))),
                metadataHash: 0
            })
        );
    }

    /// @dev A carried ERC-20 holding: `idleOnly`, excluded from N, adapter optional.
    function _holding(
        address vault,
        string memory offchainId,
        uint64 poolChainId,
        address adapter,
        address token,
        uint8 riskScore
    )
        private
    {
        _setIdle(vault, offchainId, VENUE_KIND_HOLDING, poolChainId, adapter, token, riskScore);
    }

    /// @dev A carried holding that keeps a real venue kind (e.g. fxSAVE). Unlike plain holdings,
    ///      its venue has a deployed Yo adapter, so record it (divests still execute through it).
    function _holdingOfKind(
        address vault,
        string memory offchainId,
        uint8 venueKind,
        uint64 poolChainId,
        address venueAddress,
        uint8 riskScore
    )
        private
    {
        _setIdle(
            vault, offchainId, venueKind, poolChainId, _adapterFor(venueKind, poolChainId), venueAddress, riskScore
        );
    }

    function _setIdle(
        address vault,
        string memory offchainId,
        uint8 venueKind,
        uint64 poolChainId,
        address adapter,
        address venueAddress,
        uint8 riskScore
    )
        private
    {
        registry.setPool(
            vault,
            offchainId,
            IYoPoolRegistry.PoolConfig({
                status: IYoPoolRegistry.PoolStatus.ACTIVE,
                venueKind: venueKind,
                idleOnly: true,
                riskScore: riskScore,
                exitLatencySeconds: 0,
                elasticityWad: 0,
                entrySlippageWad: 0,
                exitCostWad: 0,
                chainId: poolChainId,
                adapter: adapter,
                venueKey: bytes32(uint256(uint160(venueAddress))),
                metadataHash: 0
            })
        );
    }

    /// @dev Resolves the deployed Yo adapter for a venue kind on an execution chain. Reverts for
    ///      any (kind, chain) pair without a deployment so a new pool entry cannot silently
    ///      record a codeless adapter.
    function _adapterFor(uint8 venueKind, uint64 poolChainId) private pure returns (address) {
        _requireKnownChain(poolChainId);
        if (venueKind == VENUE_KIND_MORPHO_MARKET) return _morphoAdapterFor(poolChainId);
        if (venueKind == VENUE_KIND_ERC4626) return ERC4626_ADAPTER;
        if (venueKind == VENUE_KIND_IPOR && poolChainId != HYPEREVM) return IPOR_ADAPTER;
        if (venueKind == VENUE_KIND_LIDO && poolChainId == ETHEREUM) return LIDO_ADAPTER;
        if (venueKind == VENUE_KIND_FXSAVE && poolChainId == ETHEREUM) return FXSAVE_ADAPTER;
        revert ChainNotSupported("pool adapter", poolChainId);
    }

    function _morphoAdapterFor(uint64 poolChainId) private pure returns (address) {
        return poolChainId == HYPEREVM ? MORPHO_ADAPTER_HYPEREVM : MORPHO_ADAPTER;
    }

    function _requireKnownChain(uint64 poolChainId) private pure {
        if (poolChainId != ETHEREUM && poolChainId != BASE && poolChainId != HYPEREVM) {
            revert ChainNotSupported("pool execution chain", poolChainId);
        }
    }

    function _logVault(string memory name, address vault) private view {
        console2.log(name);
        console2.log("  pools:      ", registry.poolCount(vault));
        console2.log("  active (N): ", registry.activePoolCount(vault));
        console2.log("  epoch:      ", registry.epoch(vault));
    }
}
