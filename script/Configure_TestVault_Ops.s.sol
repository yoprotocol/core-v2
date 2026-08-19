// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { console2 } from "forge-std/src/console2.sol";

import { IYoBridgeRouteRegistry } from "../src/interfaces/IYoBridgeRouteRegistry.sol";

import { BaseScript } from "./Base.s.sol";
import { ChainId } from "./ChainId.sol";

/// @notice Ops-EOA half of the test-vault setup (the part NOT owned by the admin Safe): bridge
///         routes in the {YoBridgeRouteRegistry}, mirroring yoUSD Edge exactly — the CCTP full
///         mesh between Ethereum (domain 0), Arbitrum (3), Base (6), and HyperEVM (19). Each
///         chain's CCTP adapter may bridge the chain's USDC to the test vault's own address on the
///         other three chains.
///
///         Broadcaster must own the bridge-route registry. Idempotent: already-allowed routes are
///         skipped.
///
///         Run once per chain:
///           forge script script/Configure_TestVault_Ops.s.sol:Configure_TestVault_Ops \
///               --rpc-url <mainnet|base|arbitrum|hyperliquid> -vvv --broadcast <signer flags>
///
///         Optional env vars:
///           - VAULT:              vault proxy to configure. Defaults to the yoTest vault.
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}).
contract Configure_TestVault_Ops is BaseScript {
    error BroadcasterNotOwner(address registry, address owner, address broadcaster);

    /// @dev The yoTest vault proxy (same address on every chain, cross-chain deterministic deploy).
    address internal constant DEFAULT_VAULT = 0xcF0fE5AB46cf260EB281650E8f999237684846AA;

    /// @dev {YoBridgeRouteRegistry}, same address on every chain.
    IYoBridgeRouteRegistry internal constant ROUTE_REGISTRY =
        IYoBridgeRouteRegistry(0x5973cE676fBe8bE0ec1D2d2F371d989374FB672b);

    /// @dev {YoCctpAdapter} per chain (distinct addresses — chain-specific constructor args).
    address internal constant CCTP_ADAPTER_ETHEREUM = 0x4d8aC89776B548356e30372521F4835fa67eD298;
    address internal constant CCTP_ADAPTER_BASE = 0xe1CFEcD5292fa1e6B098cA85E10181E3675C7fa4;
    address internal constant CCTP_ADAPTER_ARBITRUM = 0x6ab918019D5F7C155AAb21b7Bd22c0aC7897b4c5;
    address internal constant CCTP_ADAPTER_HYPEREVM = 0xBb3c2B36E8517E03515C08F8A31e2746649917f4;

    function run() public broadcast {
        address vault = vm.envOr({ name: "VAULT", defaultValue: DEFAULT_VAULT });

        address registryOwner = Ownable(address(ROUTE_REGISTRY)).owner();
        if (registryOwner != broadcaster) {
            revert BroadcasterNotOwner(address(ROUTE_REGISTRY), registryOwner, broadcaster);
        }

        _setRoutes(vault);
    }

    /// @dev CCTP full mesh: from this chain's domain to the other three, recipient = the vault's
    ///      own (identical) address on the destination chain, `outputToken` unpinned (CCTP fixes
    ///      the output asset).
    function _setRoutes(address vault) internal {
        (address adapter, uint256 ownDomain) = _cctpAdapter();
        address usdc = getUSDC();
        uint256[4] memory domains = [uint256(0), 3, 6, 19];
        bytes32 recipient = bytes32(uint256(uint160(vault)));

        for (uint256 i = 0; i < domains.length; ++i) {
            uint256 destination = domains[i];
            if (destination == ownDomain) {
                continue;
            }
            if (ROUTE_REGISTRY.isRouteAllowed(vault, adapter, usdc, destination, recipient, bytes32(0))) {
                console2.log("Route to domain %s already allowed - skipping", destination);
                continue;
            }
            ROUTE_REGISTRY.setRoute(vault, adapter, usdc, destination, recipient, bytes32(0), true);
            console2.log("Route set: USDC via %s to domain %s", adapter, destination);
        }
    }

    /// @dev Chain-pinned CCTP adapter and the chain's own CCTP domain.
    function _cctpAdapter() internal view returns (address adapter, uint256 ownDomain) {
        if (chainId == ChainId.ETHEREUM) {
            return (CCTP_ADAPTER_ETHEREUM, 0);
        }
        if (chainId == ChainId.ARBITRUM) {
            return (CCTP_ADAPTER_ARBITRUM, 3);
        }
        if (chainId == ChainId.BASE) {
            return (CCTP_ADAPTER_BASE, 6);
        }
        if (chainId == ChainId.HYPEREVM) {
            return (CCTP_ADAPTER_HYPEREVM, 19);
        }
        revert ChainNotSupported("CCTP adapter", chainId);
    }
}
