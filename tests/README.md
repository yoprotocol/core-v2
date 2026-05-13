# Tests

Layout follows Sablier's `lockup` package: top-level `Base.t.sol`, integration tests split into `concrete/` + `fuzz/`, dedicated invariant subtree with `handlers/` + `stores/`. Tests are organized per public function, with one `.tree` file describing branches and one `.t.sol` implementing each leaf.

## Branching Tree Technique

For each public function on the v3 contracts there is a `.tree` file describing the test cases as a tree of conditions. Each path from root to leaf is one test in the corresponding `.t.sol`. Conditions on the path become Solidity modifiers; the leaf becomes the assertion.

Example: [`integration/concrete/approval-registry/setApproval/setApproval.tree`](integration/concrete/approval-registry/setApproval/setApproval.tree)

```
SetApproval_Integration_Concrete_Test
├── when caller not owner
│  └── it should revert
└── when caller owner
   ├── when vault zero
   │  └── it should revert with ZeroAddress
   ...
```

The matching test method is `function test_RevertWhen_CallerNotOwner()` etc. — see `setApproval.t.sol` for the fully-implemented reference.

### Generating scaffolds with `bulloak`

[bulloak](https://github.com/alexfertel/bulloak) generates Solidity scaffolds from `.tree` files. Install once:

```bash
cargo install bulloak
```

Scaffold (or refresh) a single test file from its tree:

```bash
bulloak scaffold tests/integration/concrete/morpho-adapter/supply/supply.tree
```

Validate that an existing `.t.sol` matches its `.tree`:

```bash
bulloak check tests/integration/concrete/**/*.tree
```

Add `bulloak check` to CI to catch tests drifting from their trees.

### Naming conventions

| File | Naming |
|---|---|
| Tree | `<function>.tree` (camelCase) |
| Test | `<function>.t.sol` |
| Test contract | `<Function>_<Suite>_<Kind>_Test` e.g. `SetApproval_Integration_Concrete_Test` |
| Test method | `test_<Outcome><Branch>` e.g. `test_RevertWhen_CallerNotOwner`, `test_GivenNoPriorEntry_SetsAndEmits` |
| Modifier | `when<Condition>` (mutable preconditions) or `given<Condition>` (state preconditions) |

## Suite layout

```
tests/
├── Base.t.sol                       # Top-level base (Base_Test)
├── integration/
│   ├── Integration.t.sol            # Integration_Test extends Base_Test
│   ├── concrete/
│   │   ├── approval-registry/
│   │   │   ├── setApproval/         # setApproval.tree + setApproval.t.sol
│   │   │   └── maxApproval/
│   │   ├── morpho-market-registry/
│   │   ├── swap-pair-registry/
│   │   ├── morpho-adapter/
│   │   │   ├── supply/
│   │   │   ├── withdraw/
│   │   │   └── withdrawAll/
│   │   └── swap-adapter/
│   │       └── swap/
│   └── fuzz/
│       ├── approval-registry/
│       ├── morpho-adapter/
│       └── swap-adapter/
├── invariant/
│   ├── Invariant.t.sol              # invariants live here
│   ├── handlers/                    # bounded action surface for invariant runs
│   ├── stores/                      # ground-truth tracking
│   └── README.md
├── mocks/
│   ├── MockERC20.sol
│   ├── MockMorpho.sol
│   ├── MockOneInchRouter.sol
│   └── MockSwapOracle.sol
└── utils/
    ├── Assertions.sol
    ├── Defaults.sol
    ├── Modifiers.sol                # BTT modifiers
    └── Types.sol                    # Users struct
```

## Running

```bash
# Whole suite
forge test

# One BTT test
forge test --match-path tests/integration/concrete/approval-registry/setApproval/setApproval.t.sol -vv

# Fuzz with CI run count
FOUNDRY_PROFILE=ci forge test --match-path tests/integration/fuzz/**

# Invariants only
forge test --match-path tests/invariant/**
```

## Adding a new test for a new contract

1. Add `tests/integration/concrete/<contract>/<function>/<function>.tree` describing the cases.
2. Run `bulloak scaffold` against the tree to generate the matching `.t.sol`.
3. Implement each leaf, reusing modifiers from `tests/utils/Modifiers.sol` (or adding new ones there).
4. Add a fuzz counterpart under `tests/integration/fuzz/<contract>/<function>.t.sol` for any function with non-trivial state.
5. If the function affects a protocol-wide invariant, add a handler shim under `tests/invariant/handlers/` and an `invariant_*` method on `Invariant_Test`.
6. CI: ensure `bulloak check` passes against the new tree.
