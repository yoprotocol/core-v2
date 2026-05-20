# Invariants

Protocol-wide properties that must hold across every reachable state. Run with:

```bash
forge test --match-path tests/invariant/**
```

Default config: 1_000 fuzz runs (per `foundry.toml`); CI runs 10_000.

## Invariants tracked

### Vault accounting

| Invariant                                                 | Where                                        |
| --------------------------------------------------------- | -------------------------------------------- |
| `sum(pending[u].assets) == totalPendingAssets`            | `invariant_PendingAssets_SumMatches`         |
| `sum(pending[u].shares) == balanceOf(vault)`              | `invariant_PendingShares_MatchVaultEscrow`   |
| `asset.balanceOf(vault) >= totalPendingAssets` (solvency) | `invariant_Solvency_ForPendingClaims`        |
| `totalAssets() == price * totalSupply() / 10**decimals`   | `invariant_TotalAssets_MatchesOraclePricing` |
| Per-recipient: `assets == 0 ⟺ shares == 0`                | `invariant_PendingState_AssetsAndSharesPair` |
| `cumulativeMinted - cumulativeBurned == totalSupply()`    | `invariant_ShareSupply_TracksMintsAndBurns`  |

### Rounding / conversions

| Invariant                                  | Where                                       |
| ------------------------------------------ | ------------------------------------------- |
| `previewMint(previewDeposit(x)) <= x`      | `invariant_PreviewRoundTrip_DepositMint`    |
| `previewWithdraw(previewRedeem(s)) <= s`   | `invariant_PreviewRoundTrip_RedeemWithdraw` |
| `previewDeposit` non-decreasing in assets  | `invariant_PreviewDeposit_Monotonic`        |
| `convertToShares(convertToAssets(s)) <= s` | `invariant_ConvertRoundTrip_Floors`         |

### Fees / state machine

| Invariant                                                 | Where                                        |
| --------------------------------------------------------- | -------------------------------------------- |
| `feeOnDeposit < MAX_FEE && feeOnWithdraw < MAX_FEE`       | `invariant_FeesWithinBound`                  |
| `feeRecipient balance >= cumulative fees accrued`         | `invariant_FeeRecipient_BalanceLowerBound`   |
| Pause freezes `totalSupply`                               | `invariant_Pause_FreezesSupply`              |
| Successful `approveToken(amount > 0)` had `cap >= amount` | `invariant_ApproveToken_RespectsRegistryCap` |
| Swap `amountOut` matches vault tokenOut delta             | `invariant_SwapOutput_BindsVaultDelta`       |

### Oracle

| Invariant                                                 | Where                               |
| --------------------------------------------------------- | ----------------------------------- |
| Drift / timestamp / window-rotation rules hold per update | `invariant_Oracle_DriftAndRotation` |

Combines `|latest - anchor| / anchor <= maxChangeBps`, `anchorTs <= latestTs <= now`, and "anchor
rotates only after `windowSeconds` have elapsed."

### Adapter custody (zero balance + zero allowance between txs)

| Invariant                                                 | Where                                       |
| --------------------------------------------------------- | ------------------------------------------- |
| `morphoAdapter` holds zero `loanToken`                    | `invariant_MorphoAdapter_HoldsZeroBalance`  |
| `morphoAdapter` has zero allowance to Morpho              | `invariant_MorphoAdapter_ZeroAllowance`     |
| Morpho authorization on the singleton stays intact        | `invariant_MorphoAuthorization_Intact`      |
| `swapAdapter` holds zero `tokenIn`/`tokenOut`             | `invariant_SwapAdapter_HoldsZeroBalance`    |
| `swapAdapter` has zero allowance to aggregator            | `invariant_SwapAdapter_ZeroAllowance`       |
| `yieldAdapter` holds zero asset & zero yield-vault shares | `invariant_ERC4626Adapter_HoldsZeroBalance` |
| `yieldAdapter` has zero allowance to the yield vault      | `invariant_ERC4626Adapter_ZeroAllowance`    |
| `iporAdapter` holds zero asset & zero plasma-vault shares | `invariant_IPORAdapter_HoldsZeroBalance`    |
| `iporAdapter` has zero allowance to the PlasmaVault       | `invariant_IPORAdapter_ZeroAllowance`       |
| `lidoAdapter` holds zero stETH shares / WETH / ETH        | `invariant_LidoAdapter_HoldsZeroBalance`    |
| `lidoAdapter` has zero allowance to the withdrawal queue  | `invariant_LidoAdapter_ZeroAllowance`       |

## Adding a new invariant

1. Define the property in plain English. If you can't, skip the invariant — it'll just be flaky noise.
2. Add a handler action that exercises the relevant code path. Handlers should `try`/`catch` every
   external call so they never revert; route bookkeeping through `Store` ghost variables instead.
3. Use `vm.assume` or early-`return` to skip unproductive states; never `require` in handlers.
4. Add the property as `function invariant_<name>() external view` on `Invariant_Test`.
5. Verify it fails when expected: temporarily mutate the relevant contract to violate it; ensure
   the run breaks.
