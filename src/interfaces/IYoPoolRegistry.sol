// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev Canonical on-chain identifier of a whitelisted pool: `keccak256(bytes(offchainId))`, where
///      `offchainId` is the pool identifier string used by the off-chain decision layer. Hashing
///      keeps the key fixed-size; the plain string is emitted once in `PoolSet` so indexers and
///      auditors can invert it.
type PoolId is bytes32;

/// @notice Per-vault registry of record for the pool whitelist. This contract does NOT gate
///         execution — that is enforced by the venue registries (`YoApprovalRegistry`,
///         `YoERC4626VaultRegistry`, `YoMorphoMarketRegistry`, `YoSwapPairRegistry`,
///         `YoBridgeRouteRegistry`) consulted by the adapters. Its job is to give the decision
///         layer's whitelist an on-chain home:
///           - `activePoolCount` / `poolCount` — the provable cap denominator N.
///
///         A single instance lives on the governance chain and records the whole whitelist: the
///         protocol spans multiple chains, so each pool carries the `chainId` of its execution
///         chain in `PoolConfig`. Counts are therefore global (across all execution chains) per
///         vault. `adapter` and `venueKey` are addresses/keys ON that execution chain — they are
///         records, not call targets.
///           - The governance-authored per-pool scalars (risk score, exit latency, elasticity,
///             entry slippage, exit cost), putting them on the same time-locked update path as
///             the whitelist itself.
///           - `epoch` — a per-vault counter bumped on every write, usable later as a whitelist
///             commitment hook.
/// @dev    "Whitelist a pool" is a multi-contract governance batch: authority capabilities and the
///         enforcement registries first, `setPool` here LAST, so the `PoolSet` event is the
///         canonical "pool entered the whitelist" record. The registry deliberately performs no
///         cross-checks that those prerequisites landed; fail-loud assertions belong in the
///         configure script. Offboarding runs in reverse: demote to `EXIT_ONLY`, unwind the
///         enforcement entries, then `removePool`.
interface IYoPoolRegistry {
    /// @dev Lifecycle status of a pool. `NONE` (zero value) means the pool is not whitelisted.
    ///      `EXIT_ONLY` marks a deprecated pool: existing positions may still exit, but the
    ///      decision layer must not allocate to it.
    enum PoolStatus {
        NONE,
        ACTIVE,
        EXIT_ONLY
    }

    /// @dev Governance-authored configuration of a whitelisted pool. Field order packs slot 1 to
    ///      exactly 32 bytes (four slots total).
    /// @param status             Lifecycle status; never `NONE` for a stored pool.
    /// @param venueKind          Venue family the pool executes through, as a raw ordinal. The
    ///                           kind table is off-chain (the decision layer's venue payload
    ///                           kinds); zero is reserved for "none" and rejected. Raw rather than
    ///                           an enum so appending a venue is a data change, never a registry
    ///                           redeploy — the contract validates only what it can know
    ///                           (non-zero); per-kind rules (key shape, aux fields, whether an
    ///                           adapter exists) belong to the onboarding script and the off-chain
    ///                           loader.
    /// @param idleOnly           True for a holding the vault merely carries (USDT, fxUSD): its
    ///                           value counts toward TVL, but the decision layer never allocates
    ///                           into or out of it, it needs no execution adapter (`adapter` may
    ///                           be zero), and it occupies no whitelist slot — `activePoolCount`
    ///                           skips it, so the cap denominator N counts only allocatable pools.
    /// @param riskScore          Governance risk score in [0, 100]; higher = safer.
    /// @param exitLatencySeconds Worst-case exit latency of the venue, in seconds.
    /// @param elasticityWad      Cap elasticity ε in [0, 1e18] (WAD-scaled).
    /// @param entrySlippageWad   Proportional entry cost fraction in [0, 1e18], swap-inclusive for
    ///                           cross-asset pools. Above 1e18 is rejected — a cost larger than
    ///                           the amount it applies to nets downstream quantities negative
    ///                           (same rationale as the elasticity bound).
    /// @param exitCostWad        Proportional exit cost fraction in [0, 1e18], swap-inclusive for
    ///                           cross-asset pools; same bound rationale as `entrySlippageWad`.
    /// @param chainId            The execution chain the pool lives on. `uint64` per the EIP-2294
    ///                           bound; must be non-zero.
    /// @param adapter            The deployed Yo adapter instance on `chainId` the pool executes
    ///                           through; zero only for `idleOnly` holdings.
    /// @param venueKey           Venue-specific key on `chainId`: ERC-4626 yield vault address
    ///                           left-padded to 32 bytes, Morpho market `Id`, or zero for
    ///                           singleton venues.
    /// @param metadataHash       Optional commitment to the pool's canonical off-chain metadata
    ///                           document (external aggregator ids such as DeFiLlama / vaults.fyi,
    ///                           and other labels): `keccak256` of the doc, or zero for no
    ///                           commitment. The ids themselves stay off-chain — they are join
    ///                           keys into third-party systems and can rot; the hash only proves
    ///                           which version governance last blessed.
    struct PoolConfig {
        PoolStatus status;
        uint8 venueKind;
        bool idleOnly;
        uint8 riskScore;
        uint32 exitLatencySeconds;
        uint64 elasticityWad;
        uint64 entrySlippageWad;
        uint64 exitCostWad;
        uint64 chainId;
        address adapter;
        bytes32 venueKey;
        bytes32 metadataHash;
    }

    /// @dev A roster entry paired with its stored config, as returned by {pools}. The plain
    ///      `offchainId` string is not stored on-chain — recover it from the pool's `PoolSet`
    ///      events.
    struct Pool {
        PoolId id;
        PoolConfig config;
    }

    /// @notice Emitted when a pool is added to the whitelist or its config is updated.
    /// @param vault      The YO vault the pool belongs to.
    /// @param id         The pool id, `keccak256(bytes(offchainId))`.
    /// @param config     The full stored config.
    /// @param epoch      The vault's whitelist epoch after this write.
    /// @param offchainId The plain off-chain pool identifier string, emitted so the hashed id can
    ///                   be inverted.
    event PoolSet(address indexed vault, PoolId indexed id, PoolConfig config, uint64 epoch, string offchainId);

    /// @notice Emitted when a pool is removed from the whitelist.
    event PoolRemoved(address indexed vault, PoolId indexed id, uint64 epoch);

    /// @notice Emitted when a pool is demoted from `ACTIVE` to `EXIT_ONLY` via the kill-switch.
    /// @param caller The guardian or owner that triggered the demotion.
    event PoolDemoted(address indexed vault, PoolId indexed id, address indexed caller, uint64 epoch);

    /// @notice Emitted when the guardian address changes (including at construction).
    event GuardianSet(address indexed guardian);

    error ZeroAddress();
    error RenounceDisabled();
    error EmptyOffchainId();
    error InvalidStatus();
    error InvalidVenueKind();
    error InvalidChainId();
    error InvalidRiskScore(uint8 riskScore);
    error InvalidElasticity(uint64 elasticityWad);
    error InvalidEntrySlippage(uint64 entrySlippageWad);
    error InvalidExitCost(uint64 exitCostWad);
    error PoolNotFound(PoolId id);
    error PoolActive(PoolId id);
    error PoolNotActive(PoolId id);
    error UnauthorizedCaller(address caller);

    /// @notice Add a pool to `vault`'s whitelist or update its config. Owner-only.
    /// @dev    The pool id is derived on-chain as `keccak256(bytes(offchainId))`, so the join key
    ///         cannot drift from the emitted string. `config.status` must not be `NONE` — removal
    ///         goes through {removePool}.
    /// @param vault      The YO vault the pool belongs to.
    /// @param offchainId The off-chain pool identifier string; must be non-empty.
    /// @param config     The config to store; see {PoolConfig} for field bounds.
    function setPool(address vault, string calldata offchainId, PoolConfig calldata config) external;

    /// @notice Remove a pool from `vault`'s whitelist. Owner-only.
    /// @dev    Reverts with `PoolActive` while the pool is `ACTIVE` — demote it first so a single
    ///         mis-ordered batch cannot drop a still-allocatable pool from the roster.
    function removePool(address vault, PoolId id) external;

    /// @notice Demote an `ACTIVE` pool to `EXIT_ONLY`. Callable by the guardian or the owner.
    /// @dev    The guardian's only power — an instant kill-switch that bypasses the timelocked
    ///         `setPool` path. Positions can still exit; the pool just stops receiving allocations.
    ///         Demotion (like removal) shrinks N and therefore instantly tightens the vault-share
    ///         cap on every remaining pool — intended kill-switch behavior.
    function demoteToExitOnly(address vault, PoolId id) external;

    /// @notice Set the guardian address. Owner-only. `address(0)` disables the kill-switch (the
    ///         owner can always demote).
    function setGuardian(address newGuardian) external;

    /// @notice The guardian able to demote pools to `EXIT_ONLY`; `address(0)` when disabled.
    function guardian() external view returns (address);

    /// @notice The whitelist epoch of `vault`: incremented on every `setPool`, `removePool`, and
    ///         `demoteToExitOnly` write. Starts at zero.
    function epoch(address vault) external view returns (uint64);

    /// @notice The stored config of `(vault, id)`. `status == NONE` means not whitelisted.
    function configOf(address vault, PoolId id) external view returns (PoolConfig memory);

    /// @notice The number of `ACTIVE`, allocatable (non-`idleOnly`) pools on `vault`'s whitelist —
    ///         the provable cap denominator N.
    function activePoolCount(address vault) external view returns (uint256);

    /// @notice The total roster size of `vault`'s whitelist, including `EXIT_ONLY` pools.
    function poolCount(address vault) external view returns (uint256);

    /// @notice All pool ids on `vault`'s roster, in insertion-set order (unordered after removals).
    function poolIds(address vault) external view returns (PoolId[] memory);

    /// @notice The full roster of `vault` — every pool id paired with its stored config, in the
    ///         same order as {poolIds}. One-call read for off-chain consumers.
    function pools(address vault) external view returns (Pool[] memory);

    /// @notice Derive the on-chain pool id from an off-chain identifier string.
    function computePoolId(string calldata offchainId) external pure returns (PoolId);
}
