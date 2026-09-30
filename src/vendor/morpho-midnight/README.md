# Morpho Midnight (vendored)

Unmodified copies of files from [morpho-org/midnight](https://github.com/morpho-org/midnight) at commit
`e4daeb30a318e01c3aead7c7ef88914bb380e17d`. The folder layout matches the upstream `src/` folder, so the relative
imports work without edits.

| File                                                                 | Upstream path                                                            |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `interfaces/IMidnight.sol`                                           | `src/interfaces/IMidnight.sol`                                           |
| `interfaces/IRatifier.sol`                                           | `src/interfaces/IRatifier.sol`                                           |
| `ratifiers/libraries/HashLib.sol`                                    | `src/ratifiers/libraries/HashLib.sol`                                    |
| `ratifiers/interfaces/ISetterRatifier.sol`                           | `src/ratifiers/interfaces/ISetterRatifier.sol`                           |
| `periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol` | `src/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol` |

The files keep their upstream license (`GPL-2.0-or-later`). Formatters and linters skip this folder.

`HashLib.hashOffer` does not compile on the legacy pipeline ("stack too deep"), so `foundry.toml` compiles `HashLib.sol`
and the files that import it with `via_ir`.

To check the copies against upstream:

```shell
git clone https://github.com/morpho-org/midnight /tmp/midnight && git -C /tmp/midnight checkout e4daeb3
for f in $(cd src/vendor/morpho-midnight && find . -name '*.sol'); do diff "/tmp/midnight/src/$f" "src/vendor/morpho-midnight/$f"; done
```
