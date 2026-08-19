// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { console2 } from "forge-std/src/console2.sol";

import { Id } from "../src/interfaces/IMorpho.sol";
import { IYoApprovalRegistry } from "../src/interfaces/IYoApprovalRegistry.sol";
import { IYoERC4626VaultRegistry } from "../src/interfaces/IYoERC4626VaultRegistry.sol";
import { IYoMorphoMarketRegistry } from "../src/interfaces/IYoMorphoMarketRegistry.sol";
import { IYoPoolRegistry } from "../src/interfaces/IYoPoolRegistry.sol";
import { YoPoolRegistry } from "../src/registries/YoPoolRegistry.sol";

import { BaseScript } from "./Base.s.sol";

/// @dev Minimal solmate `RolesAuthority` surface used by the onboarding batch.
interface IRolesAuthorityLike {
    function owner() external view returns (address);
    function setRoleCapability(uint8 role, address target, bytes4 functionSig, bool enabled) external;
}

/// @notice Authors the "whitelist a pool" governance bundle as a TimelockController batch and
///         writes the schedule + execute Safe Transaction Builder JSONs to `script/safe-batches/`
///         (`yo-<slug>-schedule-safe.json` / `yo-<slug>-execute-safe.json`). Nothing is broadcast:
///         run with `--rpc-url` only, then collect Safe signatures on the generated batches.
///
///         Batch order is canonical — enforcement first, registry of record LAST, so the
///         `PoolSet` event marks the instant the pool entered the whitelist:
///           1. `RolesAuthority.setRoleCapability(role, adapter, selector, true)` per selector
///              (only when the adapter is new to the authority; skipped when `YO_AUTHORITY` unset).
///           2. Venue enforcement entry — `YoERC4626VaultRegistry.setAllowed` (ERC4626/IPOR) or
///              `YoMorphoMarketRegistry.setAllowed` (MORPHO_MARKET); singleton venues (LIDO,
///              FXSAVE) have none.
///           3. `YoApprovalRegistry.setApproval(vault, token, adapter, cap)` per token leg.
///           4. `YoPoolRegistry.setPool(vault, offchainId, config)`.
///         Swap-pair and bridge-route legs for cross-asset/cross-chain pools are separate batches.
///
///         Governance lives on a single chain while the protocol spans many, so `POOL_CHAIN_ID`
///         names the pool's execution chain. When it differs from the chain the script runs on
///         (the governance chain), the enforcement legs live on the remote chain and CANNOT ride
///         in this timelock batch: the authority/venue/approval env vars must be unset, the
///         adapter code check is skipped (the adapter has no code here), and the batch records
///         `setPool` only. Execute the remote chain's enforcement writes through that chain's
///         ownership structure BEFORE executing this batch.
///
///         The script fails loud when a prerequisite is off: the adapter has no code, a written
///         registry is not owned by the timelock, the venue registry is missing/superfluous for
///         the venue kind, or a config bound is exceeded. The registry itself performs no such
///         cross-checks by design.
///
///         Required env vars:
///           - TIMELOCK, POOL_REGISTRY, POOL_VAULT: addresses.
///           - POOL_ADAPTER:      execution adapter address; optional (default zero) when
///                                POOL_IDLE_ONLY — idle holdings have no adapter.
///           - POOL_OFFCHAIN_ID:  off-chain pool identifier string (the `PoolId` preimage).
///           - POOL_VENUE_KIND:   raw venue-kind ordinal per the off-chain kind table. This
///                                script's leg-building constants copy today's ordinals
///                                (1 = ERC4626, 2 = MORPHO_MARKET, 3 = LIDO, 4 = IPOR,
///                                5 = FXSAVE); the registry itself only rejects zero.
///           - POOL_CHAIN_ID:     the pool's execution chain id.
///           - POOL_RISK_SCORE:   0..100, higher = safer.
///           - POOL_ELASTICITY_WAD: cap elasticity in [0, 1e18].
///         Optional env vars:
///           - POOL_IDLE_ONLY:    true for a carried holding (no adapter, no venue-registry leg,
///                                excluded from the cap denominator N); default false.
///           - POOL_ENTRY_SLIPPAGE_WAD / POOL_EXIT_COST_WAD: proportional cost fractions in
///                                [0, 1e18], swap-inclusive for cross-asset pools; default 0.
///           - POOL_VENUE_KEY:    bytes32 venue key (yield vault address left-padded / Morpho Id);
///                                required for ERC4626 / MORPHO_MARKET / IPOR.
///           - VENUE_REGISTRY:    the enforcement registry for the venue kind; required for
///                                ERC4626 / MORPHO_MARKET / IPOR, forbidden for LIDO / FXSAVE and
///                                for idle holdings.
///           - POOL_STATUS:       `PoolStatus` ordinal, default 1 (ACTIVE).
///           - POOL_EXIT_LATENCY_SECONDS: default 0.
///           - POOL_METADATA_HASH: keccak256 of the pool's canonical off-chain metadata document
///                                (external aggregator ids etc.); default zero (no commitment).
///           - YO_AUTHORITY + POOL_ADAPTER_SELECTORS (comma-separated 4-byte hex) + OPERATOR_ROLE
///             (default 99): the capability leg.
///           - APPROVAL_REGISTRY + POOL_TOKENS + POOL_APPROVAL_CAPS (comma-separated, aligned):
///             the approval legs.
///           - TIMELOCK_DELAY:    schedule delay; defaults to `timelock.getMinDelay()`.
///           - BATCH_SLUG:        output filename slug, default "pool-onboard".
contract Configure_Pool is BaseScript {
    /// @dev Venue-kind ordinals this script knows how to build enforcement legs for. Deliberately
    ///      non-canonical copies of the off-chain kind table (the registry stores a raw ordinal
    ///      and validates only non-zero); appending a kind off-chain does not require touching
    ///      the registry, only this script when the new kind needs an enforcement leg.
    uint8 internal constant VENUE_KIND_ERC4626 = 1;
    uint8 internal constant VENUE_KIND_MORPHO_MARKET = 2;
    uint8 internal constant VENUE_KIND_LIDO = 3;
    uint8 internal constant VENUE_KIND_IPOR = 4;
    uint8 internal constant VENUE_KIND_FXSAVE = 5;

    error AdapterHasNoCode(address adapter);
    error RemotePoolTakesNoEnforcementLegs(uint256 poolChainId, uint256 governanceChainId);
    error NotOwnedByTimelock(string what, address target, address currentOwner);
    error VenueRegistryMismatch(string reason);
    error VenueKeyRequired();
    error SelectorNot4Bytes(bytes selector);
    error ApprovalLegsMisaligned(uint256 tokens, uint256 caps);

    struct Inputs {
        TimelockController timelock;
        YoPoolRegistry poolRegistry;
        address vault;
        address adapter;
        string offchainId;
        IYoPoolRegistry.PoolConfig config;
        address authority;
        uint8 operatorRole;
        bytes[] selectors;
        address venueRegistry;
        address approvalRegistry;
        address[] tokens;
        uint256[] caps;
    }

    function run() public {
        Inputs memory inputs = _readInputs();
        _preflight(inputs);

        (address[] memory targets, bytes[] memory payloads) = _buildCalls(inputs);
        uint256[] memory values = new uint256[](targets.length);
        bytes32 salt = keccak256(bytes(string.concat("YO pool onboard: ", inputs.offchainId)));
        uint256 delay = vm.envOr({ name: "TIMELOCK_DELAY", defaultValue: inputs.timelock.getMinDelay() });

        string memory slug = vm.envOr({ name: "BATCH_SLUG", defaultValue: string("pool-onboard") });
        _writeBatch(
            string.concat("script/safe-batches/yo-", slug, "-schedule-safe.json"),
            string.concat("Onboard pool ", inputs.offchainId, " (schedule)"),
            address(inputs.timelock),
            abi.encodeCall(TimelockController.scheduleBatch, (targets, values, payloads, bytes32(0), salt, delay))
        );
        _writeBatch(
            string.concat("script/safe-batches/yo-", slug, "-execute-safe.json"),
            string.concat("Onboard pool ", inputs.offchainId, " (execute)"),
            address(inputs.timelock),
            abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, bytes32(0), salt))
        );

        console2.log("=== YO Pool Onboarding Batch Authored ===");
        console2.log("Chain ID:      ", chainId);
        console2.log("Pool:          ", inputs.offchainId);
        console2.log("Vault:         ", inputs.vault);
        console2.log("Adapter:       ", inputs.adapter);
        console2.log("Inner calls:   ", targets.length);
        console2.log("Delay:         ", delay);
        console2.log("Operation id:  ");
        console2.logBytes32(inputs.timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                       INPUTS
    //////////////////////////////////////////////////////////////////////////*/

    function _readInputs() private view returns (Inputs memory inputs) {
        inputs.timelock = TimelockController(payable(vm.envAddress("TIMELOCK")));
        inputs.poolRegistry = YoPoolRegistry(vm.envAddress("POOL_REGISTRY"));
        inputs.vault = vm.envAddress("POOL_VAULT");
        inputs.offchainId = vm.envString("POOL_OFFCHAIN_ID");
        bool idleOnly = vm.envOr({ name: "POOL_IDLE_ONLY", defaultValue: false });
        // Idle holdings need no execution adapter, so POOL_ADAPTER may be omitted for them.
        inputs.adapter =
            idleOnly ? vm.envOr({ name: "POOL_ADAPTER", defaultValue: address(0) }) : vm.envAddress("POOL_ADAPTER");
        inputs.config = IYoPoolRegistry.PoolConfig({
            status: IYoPoolRegistry.PoolStatus(vm.envOr({ name: "POOL_STATUS", defaultValue: uint256(1) })),
            venueKind: uint8(vm.envUint("POOL_VENUE_KIND")),
            idleOnly: idleOnly,
            riskScore: uint8(vm.envUint("POOL_RISK_SCORE")),
            exitLatencySeconds: uint32(vm.envOr({ name: "POOL_EXIT_LATENCY_SECONDS", defaultValue: uint256(0) })),
            elasticityWad: uint64(vm.envUint("POOL_ELASTICITY_WAD")),
            entrySlippageWad: uint64(vm.envOr({ name: "POOL_ENTRY_SLIPPAGE_WAD", defaultValue: uint256(0) })),
            exitCostWad: uint64(vm.envOr({ name: "POOL_EXIT_COST_WAD", defaultValue: uint256(0) })),
            chainId: uint64(vm.envUint("POOL_CHAIN_ID")),
            adapter: inputs.adapter,
            venueKey: vm.envOr({ name: "POOL_VENUE_KEY", defaultValue: bytes32(0) }),
            metadataHash: vm.envOr({ name: "POOL_METADATA_HASH", defaultValue: bytes32(0) })
        });
        inputs.authority = vm.envOr({ name: "YO_AUTHORITY", defaultValue: address(0) });
        inputs.operatorRole = uint8(vm.envOr({ name: "OPERATOR_ROLE", defaultValue: uint256(99) }));
        if (inputs.authority != address(0)) {
            inputs.selectors = vm.envBytes("POOL_ADAPTER_SELECTORS", ",");
        }
        inputs.venueRegistry = vm.envOr({ name: "VENUE_REGISTRY", defaultValue: address(0) });
        inputs.approvalRegistry = vm.envOr({ name: "APPROVAL_REGISTRY", defaultValue: address(0) });
        if (inputs.approvalRegistry != address(0)) {
            inputs.tokens = vm.envAddress("POOL_TOKENS", ",");
            inputs.caps = vm.envUint("POOL_APPROVAL_CAPS", ",");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      PREFLIGHT
    //////////////////////////////////////////////////////////////////////////*/

    function _preflight(Inputs memory inputs) private view {
        _requireTimelockOwned(inputs, "YoPoolRegistry", address(inputs.poolRegistry));

        // Remote pool: enforcement lives on the execution chain, so this batch may only record
        // `setPool`. The adapter code check is meaningless here — the adapter has no code on the
        // governance chain.
        if (inputs.config.chainId != chainId) {
            if (
                inputs.venueRegistry != address(0) || inputs.approvalRegistry != address(0)
                    || inputs.authority != address(0)
            ) {
                revert RemotePoolTakesNoEnforcementLegs(inputs.config.chainId, chainId);
            }
            _checkBounds(inputs);
            return;
        }

        if (!inputs.config.idleOnly && inputs.adapter.code.length == 0) {
            revert AdapterHasNoCode(inputs.adapter);
        }

        // The venue kind dictates whether an enforcement registry entry exists and which one.
        // Idle holdings are never executed against, so they take no venue-registry leg at all.
        uint8 kind = inputs.config.venueKind;
        bool needsVenueRegistry = !inputs.config.idleOnly
            && (kind == VENUE_KIND_ERC4626 || kind == VENUE_KIND_MORPHO_MARKET || kind == VENUE_KIND_IPOR);
        if (needsVenueRegistry && inputs.venueRegistry == address(0)) {
            revert VenueRegistryMismatch("VENUE_REGISTRY required for this venue kind");
        }
        if (!needsVenueRegistry && inputs.venueRegistry != address(0)) {
            revert VenueRegistryMismatch("singleton venue takes no VENUE_REGISTRY");
        }
        if (needsVenueRegistry && inputs.config.venueKey == bytes32(0)) {
            revert VenueKeyRequired();
        }
        if (inputs.venueRegistry != address(0)) {
            _requireTimelockOwned(inputs, "venue registry", inputs.venueRegistry);
        }
        if (inputs.approvalRegistry != address(0)) {
            _requireTimelockOwned(inputs, "YoApprovalRegistry", inputs.approvalRegistry);
            if (inputs.tokens.length != inputs.caps.length) {
                revert ApprovalLegsMisaligned(inputs.tokens.length, inputs.caps.length);
            }
        }
        if (inputs.authority != address(0)) {
            address authorityOwner = IRolesAuthorityLike(inputs.authority).owner();
            if (authorityOwner != address(inputs.timelock)) {
                revert NotOwnedByTimelock("RolesAuthority", inputs.authority, authorityOwner);
            }
            for (uint256 i = 0; i < inputs.selectors.length; ++i) {
                if (inputs.selectors[i].length != 4) {
                    revert SelectorNot4Bytes(inputs.selectors[i]);
                }
            }
        }

        _checkBounds(inputs);
    }

    /// @dev Mirror the registry's own bounds so the batch cannot revert at execute time.
    function _checkBounds(Inputs memory inputs) private view {
        if (inputs.config.riskScore > inputs.poolRegistry.MAX_RISK_SCORE()) {
            revert IYoPoolRegistry.InvalidRiskScore(inputs.config.riskScore);
        }
        if (inputs.config.elasticityWad > inputs.poolRegistry.MAX_ELASTICITY_WAD()) {
            revert IYoPoolRegistry.InvalidElasticity(inputs.config.elasticityWad);
        }
        if (inputs.config.entrySlippageWad > inputs.poolRegistry.MAX_COST_FRACTION_WAD()) {
            revert IYoPoolRegistry.InvalidEntrySlippage(inputs.config.entrySlippageWad);
        }
        if (inputs.config.exitCostWad > inputs.poolRegistry.MAX_COST_FRACTION_WAD()) {
            revert IYoPoolRegistry.InvalidExitCost(inputs.config.exitCostWad);
        }
    }

    function _requireTimelockOwned(Inputs memory inputs, string memory what, address target) private view {
        address currentOwner = Ownable(target).owner();
        if (currentOwner != address(inputs.timelock)) {
            revert NotOwnedByTimelock(what, target, currentOwner);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    BATCH CALLS
    //////////////////////////////////////////////////////////////////////////*/

    function _buildCalls(Inputs memory inputs) private pure returns (address[] memory, bytes[] memory) {
        uint256 count =
            1 + inputs.selectors.length + inputs.tokens.length + (inputs.venueRegistry != address(0) ? 1 : 0);
        address[] memory targets = new address[](count);
        bytes[] memory payloads = new bytes[](count);
        uint256 n = 0;

        for (uint256 i = 0; i < inputs.selectors.length; ++i) {
            targets[n] = inputs.authority;
            payloads[n++] = abi.encodeCall(
                IRolesAuthorityLike.setRoleCapability,
                (inputs.operatorRole, inputs.adapter, bytes4(inputs.selectors[i]), true)
            );
        }

        if (inputs.venueRegistry != address(0)) {
            targets[n] = inputs.venueRegistry;
            if (inputs.config.venueKind == VENUE_KIND_MORPHO_MARKET) {
                payloads[n++] = abi.encodeCall(
                    IYoMorphoMarketRegistry.setAllowed, (inputs.vault, Id.wrap(inputs.config.venueKey), true)
                );
            } else {
                address yieldVault = address(uint160(uint256(inputs.config.venueKey)));
                payloads[n++] = abi.encodeCall(IYoERC4626VaultRegistry.setAllowed, (inputs.vault, yieldVault, true));
            }
        }

        for (uint256 i = 0; i < inputs.tokens.length; ++i) {
            targets[n] = inputs.approvalRegistry;
            payloads[n++] = abi.encodeCall(
                IYoApprovalRegistry.setApproval, (inputs.vault, inputs.tokens[i], inputs.adapter, inputs.caps[i])
            );
        }

        // LAST: the registry of record — `PoolSet` is the canonical whitelist-entry event.
        targets[n] = address(inputs.poolRegistry);
        payloads[n++] = abi.encodeCall(IYoPoolRegistry.setPool, (inputs.vault, inputs.offchainId, inputs.config));

        return (targets, payloads);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    JSON OUTPUT
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Safe Transaction Builder v1.0 format, matching the hand-authored batches already in
    ///      `script/safe-batches/`. One raw-calldata transaction per file.
    function _writeBatch(string memory path, string memory description, address to, bytes memory data) private {
        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(chainId),
            '","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"',
            description,
            '","description":"',
            description,
            '","txBuilderVersion":"1.18.0",',
            '"createdFromSafeAddress":"0x0000000000000000000000000000000000000000","createdFromOwnerAddress":""},',
            '"transactions":[{"to":"',
            vm.toString(to),
            '","value":"0","data":"',
            vm.toString(data),
            '","contractMethod":null,"contractInputsValues":null}]}'
        );
        vm.writeFile(path, json);
        console2.log("Wrote:", path);
    }
}
