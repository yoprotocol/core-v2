// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { IMorpho } from "../src/interfaces/IMorpho.sol";
import { IStETH } from "../src/interfaces/external/IStETH.sol";
import { IWETH9 } from "../src/interfaces/external/IWETH9.sol";
import { IWithdrawalQueueERC721 } from "../src/interfaces/external/IWithdrawalQueueERC721.sol";
import { IYoERC4626VaultRegistry } from "../src/interfaces/IYoERC4626VaultRegistry.sol";
import { IYoMorphoMarketRegistry } from "../src/interfaces/IYoMorphoMarketRegistry.sol";
import { IYoRegistry } from "../src/interfaces/IYoRegistry.sol";
import { IYoSwapOracle } from "../src/interfaces/IYoSwapOracle.sol";
import { IYoSwapPairRegistry } from "../src/interfaces/IYoSwapPairRegistry.sol";

import { YoERC4626Adapter } from "../src/adapters/erc4626/YoERC4626Adapter.sol";
import { YoIPORAdapter } from "../src/adapters/ipor/YoIPORAdapter.sol";
import { YoLidoAdapter } from "../src/adapters/lido/YoLidoAdapter.sol";
import { YoMorphoAdapter } from "../src/adapters/morpho/YoMorphoAdapter.sol";
import { YoSwapAdapter } from "../src/adapters/swap/YoSwapAdapter.sol";

import { YoApprovalRegistry } from "../src/registries/YoApprovalRegistry.sol";
import { YoERC4626VaultRegistry } from "../src/registries/YoERC4626VaultRegistry.sol";
import { YoMorphoMarketRegistry } from "../src/registries/YoMorphoMarketRegistry.sol";
import { YoSwapPairRegistry } from "../src/registries/YoSwapPairRegistry.sol";

import { YoChainlinkOracle } from "../src/oracles/YoChainlinkOracle.sol";

import { BaseScript } from "./Base.s.sol";

/// @notice Deploys the YO V3 operator-safety stack — four non-upgradeable registries, the
///         Chainlink-backed swap oracle, and five adapters (Morpho / Swap / ERC4626 / IPOR / Lido).
///         All contracts are deployed via deterministic CREATE2 with a chain+version-scoped salt
///         so addresses are reproducible across chains.
///
///         Ordering:
///           1. Registries (no inter-dependencies)
///           2. YoChainlinkOracle (no dependencies)
///           3. Adapters (depend on registries + oracle + existing YoRegistry)
///
///         The Lido adapter is deployed only on Ethereum mainnet — the rest is chain-agnostic.
///
///         Required env vars:
///           - YO_REGISTRY: address of the live YoRegistry proxy on the target chain (used by
///                          adapter `rescue` auth). Not redeployed by this script.
///
///         Optional env vars:
///           - YO_OWNER: override the multisig that owns the new registries + swap oracle.
///                       Defaults to the chain-pinned address in {BaseScript.getYoOwner}.
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}).
contract Deploy_V3_Stack is BaseScript {
    struct Deployments {
        YoApprovalRegistry approvalRegistry;
        YoMorphoMarketRegistry morphoMarketRegistry;
        YoSwapPairRegistry swapPairRegistry;
        YoERC4626VaultRegistry yieldVaultRegistry;
        YoChainlinkOracle chainlinkOracle;
        YoMorphoAdapter morphoAdapter;
        YoSwapAdapter swapAdapter;
        YoERC4626Adapter erc4626Adapter;
        YoIPORAdapter iporAdapter;
        YoLidoAdapter lidoAdapter; // address(0) on non-mainnet chains
    }

    function run() public broadcast returns (Deployments memory d) {
        address owner = getYoOwner();
        IYoRegistry yoRegistry = IYoRegistry(getYoRegistry());
        bool lidoSupported = isLidoSupportedChain();

        d.approvalRegistry = new YoApprovalRegistry{ salt: SALT }(owner);
        d.morphoMarketRegistry = new YoMorphoMarketRegistry{ salt: SALT }(owner);
        d.swapPairRegistry = new YoSwapPairRegistry{ salt: SALT }(owner);
        d.yieldVaultRegistry = new YoERC4626VaultRegistry{ salt: SALT }(owner);

        d.chainlinkOracle = new YoChainlinkOracle{ salt: SALT }(owner);

        d.morphoAdapter = new YoMorphoAdapter{ salt: SALT }(
            IMorpho(getMorphoBlue()), IYoMorphoMarketRegistry(address(d.morphoMarketRegistry)), yoRegistry
        );

        address curveRouter = getCurveRouter();

        if (curveRouter != address(0)) {
            d.swapAdapter = new YoSwapAdapter{ salt: SALT }({
                _aggregator: getCurveRouter(),
                _oracle: IYoSwapOracle(address(d.chainlinkOracle)),
                _registry: IYoSwapPairRegistry(address(d.swapPairRegistry)),
                _maxSlippageBps: getMaxSlippageBps(),
                _yoRegistry: yoRegistry
            });
        }

        d.erc4626Adapter =
            new YoERC4626Adapter{ salt: SALT }(IYoERC4626VaultRegistry(address(d.yieldVaultRegistry)), yoRegistry);

        d.iporAdapter =
            new YoIPORAdapter{ salt: SALT }(IYoERC4626VaultRegistry(address(d.yieldVaultRegistry)), yoRegistry);

        if (lidoSupported) {
            d.lidoAdapter = new YoLidoAdapter{ salt: SALT }({
                _stETH: IStETH(getLidoStETH()),
                _queue: IWithdrawalQueueERC721(getLidoQueue()),
                _weth: IWETH9(getWETH()),
                _referral: address(0),
                _yoRegistry: yoRegistry
            });
        }

        _log(d, owner, address(yoRegistry), lidoSupported);
    }

    function _log(Deployments memory d, address owner, address yoRegistry, bool lidoSupported) internal view {
        console2.log("=== YO V3 Stack Deployed ===");
        console2.log("Chain ID:               ", chainId);
        console2.log("Version:                ", YO_VERSION);
        console2.log("Salt:                   ");
        console2.logBytes32(SALT);
        console2.log("Owner:                  ", owner);
        console2.log("YoRegistry (existing):  ", yoRegistry);
        console2.log("");
        console2.log("YoApprovalRegistry:     ", address(d.approvalRegistry));
        console2.log("YoMorphoMarketRegistry: ", address(d.morphoMarketRegistry));
        console2.log("YoSwapPairRegistry:     ", address(d.swapPairRegistry));
        console2.log("YoERC4626VaultRegistry: ", address(d.yieldVaultRegistry));
        console2.log("YoChainlinkOracle:      ", address(d.chainlinkOracle));
        console2.log("");
        console2.log("YoMorphoAdapter:        ", address(d.morphoAdapter));
        console2.log("YoSwapAdapter:          ", address(d.swapAdapter));
        console2.log("YoERC4626Adapter:       ", address(d.erc4626Adapter));
        console2.log("YoIPORAdapter:          ", address(d.iporAdapter));
        if (lidoSupported) {
            console2.log("YoLidoAdapter:          ", address(d.lidoAdapter));
        } else {
            console2.log("YoLidoAdapter:           (skipped - not Ethereum mainnet)");
        }
    }
}
