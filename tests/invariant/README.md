# Invariants

Protocol-wide properties that must hold across every reachable state. Run with:

```bash
forge test --match-path tests/invariant/**
```

Default config: 1_000 fuzz runs (per `foundry.toml`); CI runs 10_000.

## Invariants tracked

| Invariant | Where | Why |
|---|---|---|
| `morphoAdapter` holds zero `loanToken` | `Invariant_Test.invariant_MorphoAdapter_HoldsZeroBalance` | Custody invariant — adapter must never retain user funds across tx boundaries. |
| `swapAdapter` holds zero `tokenIn`/`tokenOut` | `Invariant_Test.invariant_SwapAdapter_HoldsZeroBalance` | Same. |
| `morphoAdapter` has zero allowance to Morpho | `invariant_MorphoAdapter_ZeroAllowance` | Adapter must reset allowance to zero after every supply. |
| `swapAdapter` has zero allowance to aggregator | `invariant_SwapAdapter_ZeroAllowance` | Same. |
| Adapter authorization on Morpho remains intact | `invariant_AuthorizationStillIntact` | Authorization is granted in setUp; nothing in the handlers should revoke it. |

## Adding a new invariant

1. Define the property in plain English. If you can't, skip the invariant — it'll just be flaky noise.
2. Add a handler action that exercises the relevant code path.
3. Use `vm.assume` to skip unproductive states; never `require` in handlers.
4. Add the property as `function invariant_<name>() external view` on `Invariant_Test`.
5. Verify it fails when expected: temporarily mutate the relevant adapter to violate it; ensure the run breaks.
