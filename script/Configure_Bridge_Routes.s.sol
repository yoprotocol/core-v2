// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { IYoBridgeRouteRegistry } from "../src/interfaces/IYoBridgeRouteRegistry.sol";

import { BaseScript } from "./Base.s.sol";
import { ChainId } from "./ChainId.sol";

/// @notice Allowlists the YO cross-chain bridge routes on the {YoBridgeRouteRegistry} of the chain
///         the script runs on. `setRoute` is owner-only, so the broadcaster must be the registry
///         owner (the YO multisig) — run with `--sender <multisig>` or generate a Safe batch.
///
///         The full route matrix (below) is chain-agnostic; each invocation applies only the routes
///         whose SOURCE chain equals `block.chainid`, resolving every field from the in-script
///         address book. Run once per source chain (Base / Ethereum / Arbitrum / HyperEVM).
///
///         Route matrix:
///           - yoETH:       Base <-> Ethereum  via Across, CCIP, Mayan
///           - yoEUR:       Base <-> Ethereum  via CCIP, Mayan
///           - yoBTC:       Base <-> Ethereum  via CCIP, Mayan
///           - yoUSD:       Base <-> Ethereum  via CCTP
///           - yoUSD Edge:  full mesh {Base, Ethereum, Arbitrum, HyperEVM} via CCTP
///
///         Field resolution (matches what each adapter passes to `isRouteAllowed`):
///           - vault        = the source-chain YO vault.
///           - adapter      = the source-chain bridge adapter.
///           - token        = the source-chain bridged asset (WETH / EURC / cbBTC / USDC).
///           - destinationId= the bridge's native dest id (Across chainId, CCIP selector,
///                            CCTP domain, Mayan Wormhole id).
///           - recipient    = the sibling vault on the destination chain (left-padded to bytes32).
///           - outputToken  = the destination-chain bridged asset, pinned for Across + Mayan
///                            (both name the delivered token); `0` for CCIP + CCTP (protocol-fixed).
///
///         Every address the script cannot derive lives in the "ADDRESS BOOK" section as a `TODO`
///         slot. An unfilled slot needed by a route on the current chain reverts (fail-loud) rather
///         than silently skipping — a missing address is a config error, not an unsupported route.
///
///         Optional env vars:
///           - YO_BRIDGE_ROUTE_REGISTRY: override the registry target (else the address-book value).
///           - ETH_FROM, MNEMONIC:       broadcaster key (see {BaseScript}).
contract Configure_Bridge_Routes is BaseScript {
    enum Vault {
        YoETH,
        YoEUR,
        YoBTC,
        YoUSD,
        YoUSDEdge
    }

    enum Bridge {
        Across,
        Ccip,
        Cctp,
        Mayan
    }

    struct Route {
        Vault vault;
        Bridge bridge;
        uint256 srcChainId;
        uint256 dstChainId;
    }

    error AddressNotConfigured(string what, Vault vault, uint256 forChainId);
    error AdapterNotConfigured(Bridge bridge, uint256 forChainId);
    error DestinationNotSupported(Bridge bridge, uint256 dstChainId);
    error RegistryNotConfigured(uint256 forChainId);

    function run() public broadcast {
        IYoBridgeRouteRegistry registry = IYoBridgeRouteRegistry(_registry());
        Route[] memory routes = _routes();

        console2.log("=== Configuring YO Bridge Routes ===");
        console2.log("Chain ID:  ", chainId);
        console2.log("Registry:  ", address(registry));
        console2.log("");

        uint256 applied;
        for (uint256 i; i < routes.length; ++i) {
            if (routes[i].srcChainId != chainId) {
                continue;
            }
            _applyRoute(registry, routes[i]);
            ++applied;
        }

        console2.log("");
        console2.log("Routes set:", applied);
    }

    /// @dev Resolves the six route fields for `r` and allowlists it. Reverts on any unfilled address.
    function _applyRoute(IYoBridgeRouteRegistry registry, Route memory r) internal {
        address vault = _requireVault(r.vault, r.srcChainId);
        address adapter = _requireAdapter(r.bridge, r.srcChainId);
        address token = _requireToken(r.vault, r.srcChainId);
        address destVault = _requireVault(r.vault, r.dstChainId);

        uint256 destinationId = _destinationId(r.bridge, r.dstChainId);
        bytes32 recipient = bytes32(uint256(uint160(destVault)));
        bytes32 outputToken =
            _pinsOutputToken(r.bridge) ? bytes32(uint256(uint160(_requireToken(r.vault, r.dstChainId)))) : bytes32(0);

        registry.setRoute(vault, adapter, token, destinationId, recipient, outputToken, true);

        console2.log("route set:");
        console2.log("  vault/adapter: ", vault, adapter);
        console2.log("  token/dstId:   ", token, destinationId);
        console2.log("  -> dstChain:   ", r.dstChainId);
    }

    /// @dev Across and Mayan let the operator name the delivered token, so the route pins it; CCIP and
    ///      CCTP have a protocol-fixed output, so they pass `bytes32(0)`.
    function _pinsOutputToken(Bridge bridge) internal pure returns (bool) {
        return bridge == Bridge.Across || bridge == Bridge.Mayan;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   ROUTE MATRIX
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The complete directed route set. `run()` filters to `srcChainId == block.chainid`.
    function _routes() internal pure returns (Route[] memory routes) {
        routes = new Route[](28);
        uint256 i;

        // yoETH — Base <-> Ethereum via Across, CCIP, Mayan.
        routes[i++] = Route(Vault.YoETH, Bridge.Across, ChainId.BASE, ChainId.ETHEREUM);
        routes[i++] = Route(Vault.YoETH, Bridge.Ccip, ChainId.BASE, ChainId.ETHEREUM);
        routes[i++] = Route(Vault.YoETH, Bridge.Mayan, ChainId.BASE, ChainId.ETHEREUM);
        routes[i++] = Route(Vault.YoETH, Bridge.Across, ChainId.ETHEREUM, ChainId.BASE);
        routes[i++] = Route(Vault.YoETH, Bridge.Ccip, ChainId.ETHEREUM, ChainId.BASE);
        routes[i++] = Route(Vault.YoETH, Bridge.Mayan, ChainId.ETHEREUM, ChainId.BASE);

        // yoEUR — Base <-> Ethereum via CCIP, Mayan.
        routes[i++] = Route(Vault.YoEUR, Bridge.Ccip, ChainId.BASE, ChainId.ETHEREUM);
        routes[i++] = Route(Vault.YoEUR, Bridge.Mayan, ChainId.BASE, ChainId.ETHEREUM);
        routes[i++] = Route(Vault.YoEUR, Bridge.Ccip, ChainId.ETHEREUM, ChainId.BASE);
        routes[i++] = Route(Vault.YoEUR, Bridge.Mayan, ChainId.ETHEREUM, ChainId.BASE);

        // yoBTC — Base <-> Ethereum via CCIP, Mayan.
        routes[i++] = Route(Vault.YoBTC, Bridge.Ccip, ChainId.BASE, ChainId.ETHEREUM);
        routes[i++] = Route(Vault.YoBTC, Bridge.Mayan, ChainId.BASE, ChainId.ETHEREUM);
        routes[i++] = Route(Vault.YoBTC, Bridge.Ccip, ChainId.ETHEREUM, ChainId.BASE);
        routes[i++] = Route(Vault.YoBTC, Bridge.Mayan, ChainId.ETHEREUM, ChainId.BASE);

        // yoUSD — Base <-> Ethereum via CCTP.
        routes[i++] = Route(Vault.YoUSD, Bridge.Cctp, ChainId.BASE, ChainId.ETHEREUM);
        routes[i++] = Route(Vault.YoUSD, Bridge.Cctp, ChainId.ETHEREUM, ChainId.BASE);

        // yoUSD Edge — full mesh {Base, Ethereum, Arbitrum, HyperEVM} via CCTP.
        routes[i++] = Route(Vault.YoUSDEdge, Bridge.Cctp, ChainId.BASE, ChainId.ETHEREUM);
        routes[i++] = Route(Vault.YoUSDEdge, Bridge.Cctp, ChainId.BASE, ChainId.ARBITRUM);
        routes[i++] = Route(Vault.YoUSDEdge, Bridge.Cctp, ChainId.BASE, ChainId.HYPEREVM);
        routes[i++] = Route(Vault.YoUSDEdge, Bridge.Cctp, ChainId.ARBITRUM, ChainId.BASE);
        routes[i++] = Route(Vault.YoUSDEdge, Bridge.Cctp, ChainId.ARBITRUM, ChainId.ETHEREUM);
        routes[i++] = Route(Vault.YoUSDEdge, Bridge.Cctp, ChainId.ARBITRUM, ChainId.HYPEREVM);
        routes[i++] = Route(Vault.YoUSDEdge, Bridge.Cctp, ChainId.HYPEREVM, ChainId.ETHEREUM);
        routes[i++] = Route(Vault.YoUSDEdge, Bridge.Cctp, ChainId.HYPEREVM, ChainId.BASE);
        routes[i++] = Route(Vault.YoUSDEdge, Bridge.Cctp, ChainId.HYPEREVM, ChainId.ARBITRUM);
        routes[i++] = Route(Vault.YoUSDEdge, Bridge.Cctp, ChainId.ETHEREUM, ChainId.BASE);
        routes[i++] = Route(Vault.YoUSDEdge, Bridge.Cctp, ChainId.ETHEREUM, ChainId.ARBITRUM);
        routes[i++] = Route(Vault.YoUSDEdge, Bridge.Cctp, ChainId.ETHEREUM, ChainId.HYPEREVM);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        DESTINATION IDS (per-bridge, verified)
    //////////////////////////////////////////////////////////////////////////*/

    function _destinationId(Bridge bridge, uint256 dstChainId) internal pure returns (uint256) {
        if (bridge == Bridge.Across) {
            return dstChainId; // Across keys on the raw destination chainId.
        }
        if (bridge == Bridge.Ccip) {
            return _ccipSelector(dstChainId);
        }
        if (bridge == Bridge.Cctp) {
            return _cctpDomain(dstChainId);
        }
        return _mayanWormholeId(dstChainId); // Bridge.Mayan
    }

    /// @dev Chainlink CCIP chain selectors. Source: docs.chain.link/ccip/directory/mainnet.
    function _ccipSelector(uint256 dstChainId) internal pure returns (uint256) {
        if (dstChainId == ChainId.ETHEREUM) {
            return 5_009_297_550_715_157_269;
        }
        if (dstChainId == ChainId.BASE) {
            return 15_971_525_489_660_198_786;
        }
        if (dstChainId == ChainId.ARBITRUM) {
            return 4_949_039_107_694_359_620;
        }
        if (dstChainId == ChainId.HYPEREVM) {
            return 2_442_541_497_099_098_535;
        }
        revert DestinationNotSupported(Bridge.Ccip, dstChainId);
    }

    /// @dev Circle CCTP domain ids. Source: developers.circle.com/cctp/concepts/supported-chains-and-domains.
    function _cctpDomain(uint256 dstChainId) internal pure returns (uint256) {
        if (dstChainId == ChainId.ETHEREUM) {
            return 0;
        }
        if (dstChainId == ChainId.BASE) {
            return 6;
        }
        if (dstChainId == ChainId.ARBITRUM) {
            return 3;
        }
        if (dstChainId == ChainId.HYPEREVM) {
            return 19;
        }
        revert DestinationNotSupported(Bridge.Cctp, dstChainId);
    }

    /// @dev Wormhole chain ids (Mayan routes on these). Source: wormhole.com/docs/products/reference/chain-ids.
    function _mayanWormholeId(uint256 dstChainId) internal pure returns (uint256) {
        if (dstChainId == ChainId.ETHEREUM) {
            return 2;
        }
        if (dstChainId == ChainId.BASE) {
            return 30;
        }
        if (dstChainId == ChainId.ARBITRUM) {
            return 23;
        }
        if (dstChainId == ChainId.HYPEREVM) {
            return 47;
        }
        revert DestinationNotSupported(Bridge.Mayan, dstChainId);
    }

    /*//////////////////////////////////////////////////////////////////////////
                          ADDRESS BOOK — FILL BEFORE RUNNING
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev {YoBridgeRouteRegistry} target. Env override wins; otherwise fill the per-chain slot.
    function _registry() internal view returns (address) {
        address envOverride = vm.envOr({ name: "YO_BRIDGE_ROUTE_REGISTRY", defaultValue: address(0) });
        if (envOverride != address(0)) {
            return envOverride;
        }
        // {YoBridgeRouteRegistry} from Deploy_Bridge_Stack — same address on all four chains (deployed
        // with the same owner via CREATE2).
        if (
            chainId == ChainId.BASE || chainId == ChainId.ETHEREUM || chainId == ChainId.ARBITRUM
                || chainId == ChainId.HYPEREVM
        ) {
            return 0x5973cE676fBe8bE0ec1D2d2F371d989374FB672b;
        }
        revert RegistryNotConfigured(chainId);
    }

    /// @dev Source-chain bridge adapter per (bridge, chain), from Deploy_Bridge_Stack output.
    ///      Adapters are chain-specific (they bind chain-local bridge addresses), so no two chains
    ///      share an address. Across/CCIP/Mayan are only wired on Base + Ethereum here; CCTP spans all.
    ///      TODO: fill each adapter address from the Deploy_Bridge_Stack deploy log. Every slot below
    ///      is a placeholder `address(0)` — the fail-loud guard reverts until the needed one is set.
    function _adapter(Bridge bridge, uint256 forChainId) internal pure returns (address) {
        if (bridge == Bridge.Across) {
            return _adapterAcross(forChainId);
        }
        if (bridge == Bridge.Ccip) {
            return _adapterCcip(forChainId);
        }
        if (bridge == Bridge.Mayan) {
            return _adapterMayan(forChainId);
        }
        return _adapterCctp(forChainId); // Bridge.Cctp
    }

    function _adapterAcross(uint256 forChainId) internal pure returns (address) {
        if (forChainId == ChainId.BASE) {
            return 0xed8E485c8e48917090830822Fa86465A2366f8cC;
        }
        if (forChainId == ChainId.ETHEREUM) {
            return 0x4A7104BE83093C3e1520259DA83d02461d6C7876;
        }
        return address(0);
    }

    function _adapterCcip(uint256 forChainId) internal pure returns (address) {
        if (forChainId == ChainId.BASE) {
            return 0x66C55881460Db8878BE2AfFbA36A15434cb12382;
        }
        if (forChainId == ChainId.ETHEREUM) {
            return 0x41E2Ae2271FD724DB474fD8F25012DeAdF2ad39f;
        }
        return address(0);
    }

    /// @dev Mayan lands at the same CREATE2 address on every chain (its ctor args are chain-invariant).
    function _adapterMayan(uint256 forChainId) internal pure returns (address) {
        if (forChainId == ChainId.BASE) {
            return 0xbAF91d1A64e9A86C400E3DEeA4Eb97Cf631252dA;
        }
        if (forChainId == ChainId.ETHEREUM) {
            return 0xbAF91d1A64e9A86C400E3DEeA4Eb97Cf631252dA;
        }
        return address(0);
    }

    function _adapterCctp(uint256 forChainId) internal pure returns (address) {
        if (forChainId == ChainId.BASE) {
            return 0xe1CFEcD5292fa1e6B098cA85E10181E3675C7fa4;
        }
        if (forChainId == ChainId.ETHEREUM) {
            return 0x4d8aC89776B548356e30372521F4835fa67eD298;
        }
        if (forChainId == ChainId.ARBITRUM) {
            return 0x6ab918019D5F7C155AAb21b7Bd22c0aC7897b4c5;
        }
        if (forChainId == ChainId.HYPEREVM) {
            return 0xBb3c2B36E8517E03515C08F8A31e2746649917f4;
        }
        return address(0);
    }

    /// @dev YO vault address per (vault, chain). yoETH/yoEUR/yoBTC/yoUSD live on Base + Ethereum;
    ///      yoUSD Edge lives on all four chains.
    ///      TODO: fill each deployed YO vault address. Every slot below is a placeholder `address(0)`.
    ///      Each vault is distinct — do not share a body between them.
    function _vault(Vault vault, uint256 forChainId) internal pure returns (address) {
        if (vault == Vault.YoETH) {
            return _vaultYoETH(forChainId);
        }
        if (vault == Vault.YoEUR) {
            return _vaultYoEUR(forChainId);
        }
        if (vault == Vault.YoBTC) {
            return _vaultYoBTC(forChainId);
        }
        if (vault == Vault.YoUSD) {
            return _vaultYoUSD(forChainId);
        }
        return _vaultYoUSDEdge(forChainId); // Vault.YoUSDEdge — lives on all four chains
    }

    function _vaultYoETH(uint256 forChainId) internal pure returns (address) {
        if (forChainId == ChainId.BASE) {
            return 0x3A43AEC53490CB9Fa922847385D82fe25d0E9De7;
        }
        if (forChainId == ChainId.ETHEREUM) {
            return 0x3A43AEC53490CB9Fa922847385D82fe25d0E9De7;
        }
        return address(0);
    }

    function _vaultYoEUR(uint256 forChainId) internal pure returns (address) {
        if (forChainId == ChainId.BASE) {
            return 0x50c749aE210D3977ADC824AE11F3c7fd10c871e9;
        }
        if (forChainId == ChainId.ETHEREUM) {
            return 0x50c749aE210D3977ADC824AE11F3c7fd10c871e9;
        }
        return address(0);
    }

    function _vaultYoBTC(uint256 forChainId) internal pure returns (address) {
        if (forChainId == ChainId.BASE) {
            return 0xbCbc8cb4D1e8ED048a6276a5E94A3e952660BcbC;
        }
        if (forChainId == ChainId.ETHEREUM) {
            return 0xbCbc8cb4D1e8ED048a6276a5E94A3e952660BcbC;
        }
        return address(0);
    }

    function _vaultYoUSD(uint256 forChainId) internal pure returns (address) {
        if (forChainId == ChainId.BASE) {
            return 0x0000000f2eB9f69274678c76222B35eEc7588a65;
        }
        if (forChainId == ChainId.ETHEREUM) {
            return 0x0000000f2eB9f69274678c76222B35eEc7588a65;
        }
        return address(0);
    }

    function _vaultYoUSDEdge(uint256 forChainId) internal pure returns (address) {
        if (forChainId == ChainId.BASE) {
            return 0x5DD8BFa6C5C68D05d25EF6143E05C11E26c4cDB7;
        }
        if (forChainId == ChainId.ETHEREUM) {
            return 0x5DD8BFa6C5C68D05d25EF6143E05C11E26c4cDB7;
        }
        if (forChainId == ChainId.ARBITRUM) {
            return 0x5DD8BFa6C5C68D05d25EF6143E05C11E26c4cDB7;
        }
        if (forChainId == ChainId.HYPEREVM) {
            return 0x5DD8BFa6C5C68D05d25EF6143E05C11E26c4cDB7;
        }
        return address(0);
    }

    /// @dev Bridged asset per (vault, chain). WETH/USDC come from {BaseScript}; EURC/cbBTC are pinned
    ///      here. Only Base + Ethereum are needed (the only chains yoETH/yoEUR/yoBTC touch).
    function _token(Vault vault, uint256 forChainId) internal pure returns (address) {
        if (vault == Vault.YoETH) {
            return _wethFor(forChainId);
        }
        if (vault == Vault.YoEUR) {
            return _eurc(forChainId);
        }
        if (vault == Vault.YoBTC) {
            return _cbBtc(forChainId);
        }
        // yoUSD + yoUSD Edge bridge native USDC (chain-aware, all four chains).
        return _usdcFor(forChainId);
    }

    /// @dev WETH (Base + Ethereum), resolved against the route's chain rather than `block.chainid`.
    function _wethFor(uint256 forChainId) internal pure returns (address) {
        if (forChainId == ChainId.BASE) {
            return 0x4200000000000000000000000000000000000006;
        }
        if (forChainId == ChainId.ETHEREUM) {
            return 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        }
        return address(0);
    }

    /// @dev Native USDC per chain (mirrors {BaseScript.getUSDCOrZero}; duplicated as `pure`-friendly
    ///      per-chain lookup so it resolves against the route's destination chain, not `block.chainid`).
    function _usdcFor(uint256 forChainId) internal pure returns (address) {
        if (forChainId == ChainId.ETHEREUM) {
            return 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        }
        if (forChainId == ChainId.BASE) {
            return 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        }
        if (forChainId == ChainId.ARBITRUM) {
            return 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        }
        if (forChainId == ChainId.HYPEREVM) {
            return 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
        }
        return address(0);
    }

    /// @dev Circle EURC (6 decimals) per chain. Verified on-chain via `symbol()`/`decimals()`.
    ///      Source: developers.circle.com/stablecoins/eurc-contract-addresses.
    function _eurc(uint256 forChainId) internal pure returns (address) {
        if (forChainId == ChainId.BASE) {
            return 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;
        }
        if (forChainId == ChainId.ETHEREUM) {
            return 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c;
        }
        return address(0);
    }

    /// @dev Coinbase cbBTC (8 decimals) per chain — same deterministic address on Base + Ethereum.
    ///      Verified on-chain via `symbol()`/`decimals()`.
    function _cbBtc(uint256 forChainId) internal pure returns (address) {
        if (forChainId == ChainId.BASE) {
            return 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
        }
        if (forChainId == ChainId.ETHEREUM) {
            return 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
        }
        return address(0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  FAIL-LOUD GUARDS
    //////////////////////////////////////////////////////////////////////////*/

    function _requireVault(Vault vault, uint256 forChainId) internal pure returns (address a) {
        a = _vault(vault, forChainId);
        if (a == address(0)) {
            revert AddressNotConfigured("vault", vault, forChainId);
        }
    }

    function _requireToken(Vault vault, uint256 forChainId) internal pure returns (address a) {
        a = _token(vault, forChainId);
        if (a == address(0)) {
            revert AddressNotConfigured("token", vault, forChainId);
        }
    }

    function _requireAdapter(Bridge bridge, uint256 forChainId) internal pure returns (address a) {
        a = _adapter(bridge, forChainId);
        if (a == address(0)) {
            revert AdapterNotConfigured(bridge, forChainId);
        }
    }
}
