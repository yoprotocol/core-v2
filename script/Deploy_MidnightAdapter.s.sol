// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { YoMidnightAdapter } from "../src/adapters/midnight/YoMidnightAdapter.sol";
import { IMorpho } from "../src/interfaces/IMorpho.sol";
import { IYoMorphoMarketRegistry } from "../src/interfaces/IYoMorphoMarketRegistry.sol";
import { IYoRegistry } from "../src/interfaces/IYoRegistry.sol";
import { IMidnight } from "../src/vendor/morpho-midnight/interfaces/IMidnight.sol";
import {
    IBlueBuyCallbackFactory
} from "../src/vendor/morpho-midnight/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import { ISetterRatifier } from "../src/vendor/morpho-midnight/ratifiers/interfaces/ISetterRatifier.sol";

import { BaseScript } from "./Base.s.sol";
import { ChainId } from "./ChainId.sol";

/// @notice Deploys the immutable {YoMidnightAdapter} bound to Morpho Blue, Morpho Midnight, the
///         Midnight `SetterRatifier`, and the `BlueBuyCallbackFactory`. Supported on Ethereum and
///         Base. The constructor checks that the ratifier and the factory point to the same
///         Midnight and Blue, so the deploy transaction validates the wiring.
///
///         The Midnight addresses differ per chain, so the adapter address also differs per chain.
///
///         Post-deploy steps (governance, per vault, through `vault.manage`):
///           - `callbackFactory.createBlueBuyCallback(vault, salt)` (permissionless).
///           - `Midnight.setIsAuthorized(ratifier, true, vault)`.
///           - `Midnight.setIsAuthorized(adapter, true, vault)`.
///           - `callback.setAuthorization(adapter, true)`.
///           - `marketRegistry.setAllowed(vault, blueMarketId, true)` for each funding market, and
///             `marketRegistry.setAllowed(vault, adapter.templateId(market), true)` for each template.
///           - `approvalRegistry.setApproval(vault, loanToken, adapter, cap)` then
///             `vault.approveToken(loanToken, adapter, cap)`.
///           - Grant the operator the adapter selectors only. Never grant the operator
///             `Midnight.setIsAuthorized`, `Midnight.take`, `ratifier.setIsRootRatified`, or
///             `callback.setAuthorization`.
///
///         Required env vars:
///           - YO_REGISTRY:              live YoRegistry proxy (adapter `rescue` auth).
///           - MORPHO_MARKET_REGISTRY:   live YoMorphoMarketRegistry (funding markets and templates).
///         Optional env vars:
///           - MIDNIGHT_MAX_TIME_TO_MATURITY:  seconds; default 60 days.
///           - MIDNIGHT_MAX_CONTINUOUS_FEE_CAP: WAD per second, as Midnight's `continuousFee`; default 0.
///                                              Midnight's maximum is `0.01e18 / 365 days` (1% per year).
///           - ETH_FROM, MNEMONIC:              broadcaster key (see {BaseScript}).
contract Deploy_MidnightAdapter is BaseScript {
    uint256 internal constant DEFAULT_MAX_TIME_TO_MATURITY = 60 days;

    function run() public broadcast returns (YoMidnightAdapter adapter) {
        (address midnight, address ratifier, address callbackFactory) = getMidnight();
        IYoRegistry yoRegistry = IYoRegistry(getYoRegistry());
        IYoMorphoMarketRegistry marketRegistry = IYoMorphoMarketRegistry(_requiredAddress("MORPHO_MARKET_REGISTRY"));
        uint256 maxTimeToMaturity =
            vm.envOr({ name: "MIDNIGHT_MAX_TIME_TO_MATURITY", defaultValue: DEFAULT_MAX_TIME_TO_MATURITY });
        uint256 maxContinuousFeeCap = vm.envOr({ name: "MIDNIGHT_MAX_CONTINUOUS_FEE_CAP", defaultValue: uint256(0) });

        adapter = new YoMidnightAdapter{ salt: SALT }(
            IMorpho(getMorphoBlue()),
            IMidnight(midnight),
            ISetterRatifier(ratifier),
            IBlueBuyCallbackFactory(callbackFactory),
            marketRegistry,
            maxTimeToMaturity,
            maxContinuousFeeCap,
            yoRegistry
        );

        _log(adapter);
    }

    /// @notice Morpho Midnight, its `SetterRatifier`, and its `BlueBuyCallbackFactory` per chain.
    /// @dev Source: https://docs.morpho.org/developers/contracts/addresses. Checked on chain: the
    ///      ratifier's and the factory's `MIDNIGHT()` return the Midnight address below.
    function getMidnight() public view returns (address midnight, address ratifier, address callbackFactory) {
        if (chainId == ChainId.ETHEREUM) {
            return (
                0x471686c42792F93528B000beF54bC10E3aa2045f,
                0xb72c416382c8A6399D0765CebfB032F040B00B3c,
                0x172d1FdC5f79bFe1ED46448f18541E591E5c93a7
            );
        }
        if (chainId == ChainId.BASE) {
            return (
                0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A,
                0x800B5F12A61B8198a5a6EfD794Cac6699B294d63,
                0x7337f119Eca028bD39E0e543cEf71631D2333425
            );
        }
        revert ChainNotSupported("Morpho Midnight", chainId);
    }

    function _requiredAddress(string memory name) internal view returns (address value) {
        value = vm.envOr({ name: name, defaultValue: address(0) });
        if (value == address(0)) {
            revert EnvVarRequired(name);
        }
    }

    function _log(YoMidnightAdapter adapter) internal view {
        console2.log("=== YO Midnight Adapter Deployed ===");
        console2.log("Chain ID:               ", chainId);
        console2.log("Version:                ", YO_VERSION);
        console2.log("Salt:                   ");
        console2.logBytes32(SALT);
        console2.log("");
        console2.log("YoMidnightAdapter:      ", address(adapter));
        console2.log("Morpho Blue:            ", address(adapter.morpho()));
        console2.log("Midnight:               ", address(adapter.midnight()));
        console2.log("SetterRatifier:         ", address(adapter.ratifier()));
        console2.log("BlueBuyCallbackFactory: ", address(adapter.callbackFactory()));
        console2.log("MorphoMarketRegistry:   ", address(adapter.registry()));
        console2.log("maxTimeToMaturity:      ", adapter.maxTimeToMaturity());
        console2.log("maxContinuousFeeCap:    ", adapter.maxContinuousFeeCap());
        console2.log("YoRegistry (existing):  ", address(adapter.yoRegistry()));
    }
}
