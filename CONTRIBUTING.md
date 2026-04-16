# Contributing

Feel free to dive in! Open an issue, start a discussion, or submit a PR.

## Prerequisites

- [Foundry](https://getfoundry.sh) (EVM development framework)
- [Bun](https://bun.sh) (package manager)
- [Just](https://github.com/casey/just) (command runner)
- [Bulloak](https://bulloak.dev) (BTT test scaffolding)
- [uv](https://github.com/astral-sh/uv) (tool manager for mdformat)

In addition, familiarity with [Solidity](https://soliditylang.org) is requisite.

## Set Up

Clone and install:

```shell
git clone <repo-url> && cd core-v2
bun install
just setup
```

The `setup` recipe creates `.env` from the example and installs mdformat.

Build all contracts:

```shell
just build
```

Run the test suite:

```shell
just test
```

See all available commands:

```shell
just --list
```

## Development Workflow

1. Run `just full-check` before committing to verify all linters pass
2. Run `just full-write` to auto-fix formatting issues
3. Use `just test-lite` for fast local iteration (skips optimizer and fork tests)

## Pull Requests

When making a pull request, ensure that:

- All tests pass (`just test`)
- All lint checks pass (`just full-check`)
- Concrete tests are generated using Bulloak and the Branching Tree Technique (BTT)
  - Learn more at [bulloak.dev](https://bulloak.dev)
  - Generate test scaffolds: `bulloak scaffold -wf path/to/file.tree`
- Code coverage remains the same or greater
- All new code adheres to the style guide:
  - NatSpec on all public/external functions
  - Named imports, ordered alphabetically
  - 120-character line length
- If making a change to the contracts:
  - Gas snapshots are provided and demonstrate an improvement (or acceptable deficit)
  - New tests are included for all new features or code paths
- A descriptive summary of the PR has been provided

## Environment Variables

Copy `.env.example` to `.env` and populate:

```shell
cp .env.example .env
```

You need an Alchemy API key for fork tests. Get one free at [alchemy.com](https://alchemy.com).

## VSCode Integration

Recommended extensions are listed in `.vscode/extensions.json`. Install them for the best development experience:

- [even-better-toml](https://marketplace.visualstudio.com/items?itemName=tamasfe.even-better-toml)
- [hardhat-solidity](https://marketplace.visualstudio.com/items?itemName=NomicFoundation.hardhat-solidity)
- [prettier-vscode](https://marketplace.visualstudio.com/items?itemName=esbenp.prettier-vscode)
- [solidity-inspector](https://marketplace.visualstudio.com/items?itemName=PraneshASP.vscode-solidity-inspector)
