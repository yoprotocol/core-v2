# core-v2

Solidity smart contracts for the core-v2 protocol.

## Tech Stack

- [Foundry](https://getfoundry.sh) — Solidity development framework
- [Bun](https://bun.sh) — package manager
- [Just](https://github.com/casey/just) — command runner
- [Bulloak](https://bulloak.dev) — BTT test scaffolding
- [Solhint](https://github.com/protofire/solhint) — Solidity linter
- [Prettier](https://prettier.io) — formatter for non-Solidity files
- [mdformat](https://mdformat.readthedocs.io) — Markdown formatter

## Getting Started

### Prerequisites

Install the required tools:

- [Foundry](https://getfoundry.sh)
- [Bun](https://bun.sh) (>=1.3)
- [Just](https://github.com/casey/just)
- [Bulloak](https://bulloak.dev)
- [uv](https://github.com/astral-sh/uv) (for mdformat)

### Setup

```sh
git clone <repo-url> && cd core-v2
bun install
just setup
```

The `setup` recipe installs dependencies, creates `.env` from the example, and installs mdformat.

## Usage

Run `just --list` to see all available commands. Key recipes:

### Build

```sh
just build        # or: just b
just build-optimized  # production build with via_ir
```

### Test

```sh
just test         # full test suite (just t)
just test-lite    # fast — no optimizer, skips fork tests (just tl)
just test-optimized   # test against optimized artifacts (just to)
just test-bulloak # check BTT compliance (just tb)
```

### Format & Lint

```sh
just full-check   # run ALL checks: mdformat, solhint, forge fmt, prettier (just fc)
just full-write   # auto-fix ALL formatting issues (just fw)
```

Individual checks:

```sh
just fmt-check / just fmt-write         # Forge formatter
just solhint-check / just solhint-write # Solidity linter (just sc / sw)
just prettier-check / just prettier-write   # JSON, YAML, SVG (just pc / pw)
just mdformat-check / just mdformat-write   # Markdown (just mc / mw)
```

### Clean

```sh
just clean        # remove build artifacts (just c)
```

### Coverage

```sh
just coverage     # generate lcov + HTML report (just cov)
```

Requires [`lcov`](https://formulae.brew.sh/formula/lcov) installed (`brew install lcov`).

### Gas Report

```sh
just gas-report   # or: just gr
```

### Deploy

```sh
just deploy --rpc-url <rpc> --private-key <key>
```

## Foundry Profiles

| Profile          | Purpose                                     | Activate                         |
| ---------------- | ------------------------------------------- | -------------------------------- |
| `default`        | Standard dev — optimizer on, 1k fuzz runs   | (default)                        |
| `lite`           | Fast iteration — no optimizer, 10 fuzz runs | `FOUNDRY_PROFILE=lite`           |
| `optimized`      | Production — via_ir, separate output        | `FOUNDRY_PROFILE=optimized`      |
| `test-optimized` | Test optimized artifacts                    | `FOUNDRY_PROFILE=test-optimized` |

## Installing Dependencies

This project uses Node.js packages (not git submodules) for dependency management:

1. Install: `bun install dependency-name`
2. Add a remapping in [remappings.txt](./remappings.txt)

OpenZeppelin Contracts is pre-installed as a reference.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

This project is licensed under MIT.
