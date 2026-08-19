// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IYoPoolRegistry, PoolId } from "../interfaces/IYoPoolRegistry.sol";

/// @title  YoPoolRegistry
/// @notice Per-vault registry of record for the pool whitelist — the enumerable roster, the
///         governance-authored per-pool scalars, and the whitelist epoch. A single instance on
///         the governance chain records pools across every execution chain (each pool carries its
///         `chainId`). See `IYoPoolRegistry` for the decision-layer rationale; this contract does
///         not gate execution.
/// @dev    Adds are owner-only (intended to sit behind the timelock as the LAST call of the
///         onboarding batch). The guardian holds exactly one power — demoting a pool to
///         `EXIT_ONLY` — so emergency de-listing does not wait out the timelock delay.
contract YoPoolRegistry is Ownable2Step, IYoPoolRegistry {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Upper bound of `PoolConfig.riskScore`.
    uint8 public constant MAX_RISK_SCORE = 100;

    /// @notice Upper bound of `PoolConfig.elasticityWad` (WAD, i.e. ε = 1).
    uint64 public constant MAX_ELASTICITY_WAD = 1e18;

    /// @notice Upper bound of `PoolConfig.entrySlippageWad` / `PoolConfig.exitCostWad` — a cost
    ///         fraction above 1 (WAD) would net downstream quantities negative.
    uint64 public constant MAX_COST_FRACTION_WAD = 1e18;

    /// @inheritdoc IYoPoolRegistry
    address public guardian;

    /// @inheritdoc IYoPoolRegistry
    mapping(address vault => uint64 currentEpoch) public epoch;

    /// @dev Enumerable per-vault roster of pool ids (both `ACTIVE` and `EXIT_ONLY`). Enumerability
    ///      is load-bearing: the roster size is the cap denominator N, a protocol input.
    mapping(address vault => EnumerableSet.Bytes32Set ids) private _roster;

    /// @dev O(1) count of `ACTIVE`, allocatable (non-`idleOnly`) pools per vault — the cap
    ///      denominator N — maintained on every status / `idleOnly` transition.
    mapping(address vault => uint256 count) private _activeCount;

    mapping(address vault => mapping(PoolId id => PoolConfig config)) private _configs;

    constructor(address initialOwner, address initialGuardian) Ownable(initialOwner) {
        if (initialOwner == address(0)) {
            revert ZeroAddress();
        }
        // A zero guardian is valid — it disables the kill-switch until `setGuardian`.
        guardian = initialGuardian;
        emit GuardianSet(initialGuardian);
    }

    /// @notice Disabled — renouncing ownership would freeze the whitelist irrevocably (pools could
    ///         never be added, updated, or removed), an open failure mode. Ownership can still be
    ///         transferred.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @inheritdoc IYoPoolRegistry
    function setPool(address vault, string calldata offchainId, PoolConfig calldata config) external onlyOwner {
        if (vault == address(0) || (config.adapter == address(0) && !config.idleOnly)) {
            revert ZeroAddress();
        }
        if (bytes(offchainId).length == 0) {
            revert EmptyOffchainId();
        }
        _validateConfig(config);

        PoolId id = computePoolId(offchainId);
        PoolConfig storage previous = _configs[vault][id];
        bool wasCounted = previous.status == PoolStatus.ACTIVE && !previous.idleOnly;
        bool nowCounted = config.status == PoolStatus.ACTIVE && !config.idleOnly;
        if (nowCounted && !wasCounted) {
            _activeCount[vault] += 1;
        } else if (wasCounted && !nowCounted) {
            _activeCount[vault] -= 1;
        }

        _roster[vault].add(PoolId.unwrap(id));
        _configs[vault][id] = config;
        uint64 newEpoch = ++epoch[vault];
        emit PoolSet(vault, id, config, newEpoch, offchainId);
    }

    /// @inheritdoc IYoPoolRegistry
    function removePool(address vault, PoolId id) external onlyOwner {
        if (_configs[vault][id].status == PoolStatus.ACTIVE) {
            revert PoolActive(id);
        }
        if (!_roster[vault].remove(PoolId.unwrap(id))) {
            revert PoolNotFound(id);
        }

        delete _configs[vault][id];
        uint64 newEpoch = ++epoch[vault];
        emit PoolRemoved(vault, id, newEpoch);
    }

    /// @inheritdoc IYoPoolRegistry
    function demoteToExitOnly(address vault, PoolId id) external {
        if (msg.sender != guardian && msg.sender != owner()) {
            revert UnauthorizedCaller(msg.sender);
        }

        PoolConfig storage config = _configs[vault][id];
        if (config.status != PoolStatus.ACTIVE) {
            revert PoolNotActive(id);
        }

        config.status = PoolStatus.EXIT_ONLY;
        // Only allocatable pools hold a whitelist slot; demoting an `idleOnly` row is legal and
        // leaves N untouched.
        if (!config.idleOnly) {
            _activeCount[vault] -= 1;
        }
        uint64 newEpoch = ++epoch[vault];
        emit PoolDemoted(vault, id, msg.sender, newEpoch);
    }

    /// @inheritdoc IYoPoolRegistry
    function setGuardian(address newGuardian) external onlyOwner {
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    /// @inheritdoc IYoPoolRegistry
    function configOf(address vault, PoolId id) external view returns (PoolConfig memory) {
        return _configs[vault][id];
    }

    /// @inheritdoc IYoPoolRegistry
    function activePoolCount(address vault) external view returns (uint256) {
        return _activeCount[vault];
    }

    /// @inheritdoc IYoPoolRegistry
    function poolCount(address vault) external view returns (uint256) {
        return _roster[vault].length();
    }

    /// @inheritdoc IYoPoolRegistry
    function poolIds(address vault) external view returns (PoolId[] memory ids) {
        bytes32[] memory raw = _roster[vault].values();
        ids = new PoolId[](raw.length);
        for (uint256 i = 0; i < raw.length; ++i) {
            ids[i] = PoolId.wrap(raw[i]);
        }
    }

    /// @inheritdoc IYoPoolRegistry
    function pools(address vault) external view returns (Pool[] memory list) {
        bytes32[] memory raw = _roster[vault].values();
        list = new Pool[](raw.length);
        for (uint256 i = 0; i < raw.length; ++i) {
            PoolId id = PoolId.wrap(raw[i]);
            list[i] = Pool({ id: id, config: _configs[vault][id] });
        }
    }

    /// @inheritdoc IYoPoolRegistry
    function computePoolId(string calldata offchainId) public pure returns (PoolId) {
        return PoolId.wrap(keccak256(bytes(offchainId)));
    }

    /// @dev Field-bound checks shared by every `setPool` path.
    function _validateConfig(PoolConfig calldata config) private pure {
        if (config.status == PoolStatus.NONE) {
            revert InvalidStatus();
        }
        if (config.venueKind == 0) {
            revert InvalidVenueKind();
        }
        if (config.chainId == 0) {
            revert InvalidChainId();
        }
        if (config.riskScore > MAX_RISK_SCORE) {
            revert InvalidRiskScore(config.riskScore);
        }
        if (config.elasticityWad > MAX_ELASTICITY_WAD) {
            revert InvalidElasticity(config.elasticityWad);
        }
        if (config.entrySlippageWad > MAX_COST_FRACTION_WAD) {
            revert InvalidEntrySlippage(config.entrySlippageWad);
        }
        if (config.exitCostWad > MAX_COST_FRACTION_WAD) {
            revert InvalidExitCost(config.exitCostWad);
        }
    }
}
