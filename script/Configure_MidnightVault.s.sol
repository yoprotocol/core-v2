// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { YoMidnightAdapter } from "../src/adapters/midnight/YoMidnightAdapter.sol";
import { IBlueBuyCallback } from "../src/interfaces/external/IBlueBuyCallback.sol";
import { Id } from "../src/interfaces/IMorpho.sol";
import { IYoApprovalRegistry } from "../src/interfaces/IYoApprovalRegistry.sol";
import { IYoMidnightRegistry } from "../src/interfaces/IYoMidnightRegistry.sol";
import { IYoMorphoMarketRegistry } from "../src/interfaces/IYoMorphoMarketRegistry.sol";
import { IMidnight } from "../src/vendor/morpho-midnight/interfaces/IMidnight.sol";
import {
    IBlueBuyCallbackFactory
} from "../src/vendor/morpho-midnight/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import { YoVault } from "../src/YoVault.sol";

import { ChainId } from "./ChainId.sol";
import {
    IBlueAuthorization,
    IBlueBuyCallbackAuthorization,
    IOwnable,
    IRolesAuthorityMidnight,
    MidnightSafeBatch
} from "./MidnightSafeBatch.sol";

/// @notice Writes the admin Safe batch that enables a vault on a deployed {YoMidnightAdapter}, as a Safe
///         Transaction Builder JSON in `script/safe-batches/`. Nothing is broadcast: run with `--rpc-url` only.
///         The script executes the batch as the Safe on the fork, checks the result, and then writes the file.
///
///         The vault, the shared `RolesAuthority`, the market registry, the approval registry, and the
///         {YoMidnightRegistry} must have the same owner: the Safe that executes the batch. The batch:
///           1. `callbackFactory.createBlueBuyCallback(vault, salt)` when the vault has no callback.
///           2. `setRoleCapability(operatorRole, adapter, selector, true)` for the six adapter selectors.
///           3. `marketRegistry.setAllowed(vault, id, true)` for each family and funding market.
///           4. `approvalRegistry.setApproval(vault, asset, adapter, approvalCap)`.
///           5. `midnightRegistry.setCap(vault, cap)`.
///           6. Vault-owned authorizations, through `vault.manage` under a temporary role for the Safe:
///              `Midnight.setIsAuthorized(ratifier)`, `Midnight.setIsAuthorized(adapter)`, and
///              `callback.setAuthorization(adapter)`. The batch removes the temporary role and its capabilities.
///         Each step is left out when the chain already has its result, so the script can run again. Anyone can
///         create the callback: if it exists when the Safe executes, step 1 reverts, so build the batch again.
///
///         Run:
///           MIDNIGHT_ADAPTER=0x... MIDNIGHT_REGISTRY=0x... MIDNIGHT_CAP=... \
///               forge script script/Configure_MidnightVault.s.sol --rpc-url mainnet -vvv
///
///         Required env vars:
///           - MIDNIGHT_ADAPTER:  the deployed {YoMidnightAdapter}.
///           - MIDNIGHT_REGISTRY: the deployed {YoMidnightRegistry}; must be the adapter's `midnightRegistry`.
///           - MIDNIGHT_CAP:      the vault's cap, in the vault's asset (for example 1_000_000e6 for 1M USDC).
///         Optional env vars:
///           - VAULT:                        default yoUSD.
///           - MIDNIGHT_FAMILY_IDS:          comma-separated Morpho market family ids; on Ethereum, default
///                                           USDC loan / cbBTC collateral.
///           - MIDNIGHT_FUNDING_MARKET_IDS:  comma-separated Blue market ids for the callback; on Ethereum,
///                                           default Blue cbBTC/USDC 86%.
///           - MIDNIGHT_APPROVAL_CAP:        largest `approveToken` amount for the adapter; default MIDNIGHT_CAP.
///           - CALLBACK_SALT:                `BlueBuyCallbackFactory` salt; default 0.
///           - OPERATOR_ROLE:                default 12.
///           - TEMP_ROLE:                    role the Safe holds during the batch; default 250. Must not hold the
///                                           Safe or the batch's capabilities.
///           - BATCH_SLUG:                   output file name `yo-<slug>-safe.json`; default "midnight-enable".
contract Configure_MidnightVault is MidnightSafeBatch {
    error AdapterHasNoCode(address adapter);
    error RegistryMismatch(address expected, address actual);
    error FundingMarketNotVaultAsset(Id marketId, address loanToken, address asset);

    address internal constant YO_USD = 0x0000000f2eB9f69274678c76222B35eEc7588a65;
    /// @dev Morpho `market_family_id` of the Midnight USDC / cbBTC markets on Ethereum.
    bytes32 internal constant ETHEREUM_CBBTC_USDC_FAMILY =
        0x92ddba8234595212f5b76d5b908690a05dfe2282d6e0af714fa9e73ac27b68e1;
    /// @dev Blue cbBTC/USDC 86% on Ethereum.
    bytes32 internal constant ETHEREUM_CBBTC_USDC_BLUE_MARKET =
        0x64d65c9a2d91c36d56fbc42d69e979335320169b3df63bf92789e2c8883fcc64;

    struct Inputs {
        YoVault vault;
        YoMidnightAdapter adapter;
        IYoMidnightRegistry midnightRegistry;
        bytes32[] familyIds;
        bytes32[] fundingMarketIds;
        uint256 cap;
        uint256 approvalCap;
        bytes32 callbackSalt;
        uint8 operatorRole;
        uint8 tempRole;
    }

    function run() public {
        Inputs memory inputs = readInputs();
        Call[] memory calls = build(inputs);
        address safe = inputs.vault.owner();

        uint256 snapshot = vm.snapshotState();
        execute(safe, calls);
        verify(inputs);
        vm.revertToState(snapshot);

        string memory slug = vm.envOr({ name: "BATCH_SLUG", defaultValue: string("midnight-enable") });
        _writeBatch(
            string.concat("script/safe-batches/yo-", slug, "-safe.json"),
            string.concat("Enable Midnight for ", inputs.vault.symbol()),
            safe,
            calls
        );
    }

    /// @notice The inputs from the env vars. See the contract NatSpec.
    function readInputs() public view returns (Inputs memory inputs) {
        inputs.vault = YoVault(payable(vm.envOr({ name: "VAULT", defaultValue: YO_USD })));
        inputs.adapter = YoMidnightAdapter(vm.envAddress("MIDNIGHT_ADAPTER"));
        inputs.midnightRegistry = IYoMidnightRegistry(vm.envAddress("MIDNIGHT_REGISTRY"));
        inputs.cap = vm.envUint("MIDNIGHT_CAP");
        inputs.approvalCap = vm.envOr({ name: "MIDNIGHT_APPROVAL_CAP", defaultValue: inputs.cap });
        inputs.callbackSalt = vm.envOr({ name: "CALLBACK_SALT", defaultValue: bytes32(0) });
        inputs.operatorRole = SafeCast.toUint8(vm.envOr({ name: "OPERATOR_ROLE", defaultValue: uint256(12) }));
        inputs.tempRole = SafeCast.toUint8(vm.envOr({ name: "TEMP_ROLE", defaultValue: uint256(250) }));

        bytes32[] memory families;
        bytes32[] memory fundingMarkets;
        if (chainId == ChainId.ETHEREUM) {
            families = new bytes32[](1);
            families[0] = ETHEREUM_CBBTC_USDC_FAMILY;
            fundingMarkets = new bytes32[](1);
            fundingMarkets[0] = ETHEREUM_CBBTC_USDC_BLUE_MARKET;
        }
        inputs.familyIds = vm.envOr({ name: "MIDNIGHT_FAMILY_IDS", delim: ",", defaultValue: families });
        inputs.fundingMarketIds =
            vm.envOr({ name: "MIDNIGHT_FUNDING_MARKET_IDS", delim: ",", defaultValue: fundingMarkets });
        if (inputs.familyIds.length == 0) {
            revert EnvVarRequired("MIDNIGHT_FAMILY_IDS");
        }
        if (inputs.fundingMarketIds.length == 0) {
            revert EnvVarRequired("MIDNIGHT_FUNDING_MARKET_IDS");
        }
    }

    /// @notice The batch calls, in order, after the preflight checks. Changes no state: it predicts the
    ///         callback address in a snapshot that it reverts.
    function build(Inputs memory inputs) public returns (Call[] memory calls) {
        address safe = _preflight(inputs);
        Call[] memory buffer = new Call[](64);
        uint256 n;
        address callback;
        (callback, n) = _callbackCalls(inputs, buffer, n);
        n = _governanceCalls(inputs, buffer, n);
        n = _ownedCalls(inputs, callback, safe, buffer, n);

        calls = _trim(buffer, n);
    }

    /// @dev Create the vault's callback when it has none. The address comes from a reverted snapshot.
    function _callbackCalls(
        Inputs memory inputs,
        Call[] memory calls,
        uint256 n
    )
        internal
        returns (address callback, uint256)
    {
        address vault = address(inputs.vault);
        IBlueBuyCallbackFactory factory = inputs.adapter.callbackFactory();
        callback = factory.callbackOf(vault, inputs.callbackSalt);
        if (callback == address(0)) {
            uint256 snapshot = vm.snapshotState();
            callback = factory.createBlueBuyCallback(vault, inputs.callbackSalt);
            vm.revertToState(snapshot);
            calls[n++] = Call(
                address(factory),
                abi.encodeCall(IBlueBuyCallbackFactory.createBlueBuyCallback, (vault, inputs.callbackSalt))
            );
        }
        return (callback, n);
    }

    /// @dev Operator capabilities, market registry ids, approval cap, and Midnight cap.
    function _governanceCalls(Inputs memory inputs, Call[] memory calls, uint256 n) internal view returns (uint256) {
        YoMidnightAdapter adapter = inputs.adapter;
        address vault = address(inputs.vault);
        IRolesAuthorityMidnight authority = IRolesAuthorityMidnight(address(inputs.vault.authority()));
        IYoMorphoMarketRegistry marketRegistry = adapter.registry();

        bytes4[6] memory selectors = _operatorSelectors();
        for (uint256 i = 0; i < selectors.length; ++i) {
            if (!authority.doesRoleHaveCapability(inputs.operatorRole, address(adapter), selectors[i])) {
                calls[n++] = Call(
                    address(authority),
                    abi.encodeCall(
                        IRolesAuthorityMidnight.setRoleCapability,
                        (inputs.operatorRole, address(adapter), selectors[i], true)
                    )
                );
            }
        }

        bytes32[] memory ids = _concat(inputs.familyIds, inputs.fundingMarketIds);
        for (uint256 i = 0; i < ids.length; ++i) {
            if (!marketRegistry.isAllowed(vault, Id.wrap(ids[i]))) {
                calls[n++] = Call(
                    address(marketRegistry),
                    abi.encodeCall(IYoMorphoMarketRegistry.setAllowed, (vault, Id.wrap(ids[i]), true))
                );
            }
        }

        IYoApprovalRegistry approvalRegistry = inputs.vault.approvalRegistry();
        address asset = inputs.vault.asset();
        if (approvalRegistry.maxApproval(vault, asset, address(adapter)) != inputs.approvalCap) {
            calls[n++] = Call(
                address(approvalRegistry),
                abi.encodeCall(IYoApprovalRegistry.setApproval, (vault, asset, address(adapter), inputs.approvalCap))
            );
        }

        if (inputs.midnightRegistry.cap(vault) != inputs.cap) {
            calls[n++] = Call(
                address(inputs.midnightRegistry), abi.encodeCall(IYoMidnightRegistry.setCap, (vault, inputs.cap))
            );
        }
        return n;
    }

    /// @dev Vault-owned calls: `manage` checks the authority for the caller, also for the owner.
    function _ownedCalls(
        Inputs memory inputs,
        address callback,
        address safe,
        Call[] memory calls,
        uint256 n
    )
        internal
        view
        returns (uint256)
    {
        YoMidnightAdapter adapter = inputs.adapter;
        address vault = address(inputs.vault);
        IMidnight midnight = adapter.midnight();
        Call[] memory owned = new Call[](3);
        uint256 m;
        address ratifier = address(adapter.ratifier());
        if (!midnight.isAuthorized(vault, ratifier)) {
            owned[m++] = Call(address(midnight), abi.encodeCall(IMidnight.setIsAuthorized, (ratifier, true, vault)));
        }
        if (!midnight.isAuthorized(vault, address(adapter))) {
            owned[m++] =
                Call(address(midnight), abi.encodeCall(IMidnight.setIsAuthorized, (address(adapter), true, vault)));
        }
        if (!IBlueAuthorization(address(adapter.morpho())).isAuthorized(callback, address(adapter))) {
            owned[m++] = Call(
                callback, abi.encodeCall(IBlueBuyCallbackAuthorization.setAuthorization, (address(adapter), true))
            );
        }
        if (m > 0) {
            IRolesAuthorityMidnight authority = IRolesAuthorityMidnight(address(inputs.vault.authority()));
            n = _appendOwned(calls, n, owned, m, authority, vault, safe, inputs.tempRole);
        }
        return n;
    }

    /// @notice Revert unless the chain has the state that the batch sets.
    function verify(Inputs memory inputs) public view {
        YoMidnightAdapter adapter = inputs.adapter;
        address vault = address(inputs.vault);
        address safe = inputs.vault.owner();
        IRolesAuthorityMidnight authority = IRolesAuthorityMidnight(address(inputs.vault.authority()));
        IMidnight midnight = adapter.midnight();

        address callback = adapter.callbackFactory().callbackOf(vault, inputs.callbackSalt);
        _require(callback != address(0) && IBlueBuyCallback(callback).OWNER() == vault, "callback");
        _require(midnight.isAuthorized(vault, address(adapter.ratifier())), "Midnight authorizes the ratifier");
        _require(midnight.isAuthorized(vault, address(adapter)), "Midnight authorizes the adapter");
        _require(
            IBlueAuthorization(address(adapter.morpho())).isAuthorized(callback, address(adapter)),
            "the callback authorizes the adapter on Blue"
        );

        bytes4[6] memory selectors = _operatorSelectors();
        for (uint256 i = 0; i < selectors.length; ++i) {
            _require(
                authority.doesRoleHaveCapability(inputs.operatorRole, address(adapter), selectors[i]),
                "operator capability"
            );
        }
        bytes32[] memory ids = _concat(inputs.familyIds, inputs.fundingMarketIds);
        for (uint256 i = 0; i < ids.length; ++i) {
            _require(adapter.registry().isAllowed(vault, Id.wrap(ids[i])), "market registry allows the id");
        }
        _require(
            inputs.vault.approvalRegistry().maxApproval(vault, inputs.vault.asset(), address(adapter))
                == inputs.approvalCap,
            "approval cap"
        );
        _require(inputs.midnightRegistry.cap(vault) == inputs.cap, "Midnight cap");

        _requireTempRoleCleared(authority, safe, inputs.tempRole, address(midnight), callback);
    }

    function _preflight(Inputs memory inputs) internal view returns (address safe) {
        YoMidnightAdapter adapter = inputs.adapter;
        if (address(adapter).code.length == 0) {
            revert AdapterHasNoCode(address(adapter));
        }
        if (address(adapter.midnightRegistry()) != address(inputs.midnightRegistry)) {
            revert RegistryMismatch(address(adapter.midnightRegistry()), address(inputs.midnightRegistry));
        }

        safe = inputs.vault.owner();
        IRolesAuthorityMidnight authority = IRolesAuthorityMidnight(address(inputs.vault.authority()));
        _requireOwner("authority", authority.owner(), safe);
        _requireOwner("market registry", IOwnable(address(adapter.registry())).owner(), safe);
        _requireOwner("approval registry", IOwnable(address(inputs.vault.approvalRegistry())).owner(), safe);
        _requireOwner("Midnight registry", IOwnable(address(inputs.midnightRegistry)).owner(), safe);

        address asset = inputs.vault.asset();
        for (uint256 i = 0; i < inputs.fundingMarketIds.length; ++i) {
            Id id = Id.wrap(inputs.fundingMarketIds[i]);
            address loanToken = adapter.morpho().idToMarketParams(id).loanToken;
            if (loanToken != asset) {
                revert FundingMarketNotVaultAsset(id, loanToken, asset);
            }
        }
    }

    function _concat(bytes32[] memory a, bytes32[] memory b) internal pure returns (bytes32[] memory c) {
        c = new bytes32[](a.length + b.length);
        for (uint256 i = 0; i < a.length; ++i) {
            c[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; ++i) {
            c[a.length + i] = b[i];
        }
    }
}
