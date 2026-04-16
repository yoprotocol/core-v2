# core-v2

Solidity smart contracts for the core-v2 protocol.

## Tech Stack

- **Language**: Solidity 0.8.29
- **Framework**: Foundry
- **Package Manager**: Bun
- **Task Runner**: Just
- **Testing**: Foundry with Bulloak (BTT)
- **Linting**: Solhint, Prettier, mdformat

## Code Standards

- Line length: 120 characters (Solidity), 128 characters (Solhint max)
- Indent: 4 spaces for Solidity and justfiles, 2 spaces elsewhere
- Use NatSpec for all public/external functions
- Follow Solidity style guide naming: `camelCase` for functions/variables, `PascalCase` for contracts/structs/events
- Imports must be named (`import { Foo } from "..."`) and ordered
- One contract per file for production code (tests may co-locate helpers)

## Development Workflow

1. Run `just setup` after cloning (installs deps, creates `.env`, installs mdformat)
2. Run `just full-check` (alias `fc`) before committing — runs all linters and formatters in check mode
3. Run `just full-write` (alias `fw`) to auto-fix all formatting issues
4. Run `just test` (alias `t`) to run the full test suite
5. Run `just test-lite` (alias `tl`) for fast iteration (skips optimizer and fork tests)

## Testing

- Tests use the Branching Tree Technique (BTT) with `.tree` files
- Generate test scaffolds: `bulloak scaffold -wf path/to/file.tree`
- Check BTT compliance: `just test-bulloak` (alias `tb`)
- Fuzz tests: prefix with `testFuzz_`
- Fork tests: prefix with `testFork_`
- Invariant tests go in `tests/invariant/`
- Use `FOUNDRY_PROFILE=lite` for fast local iteration

## Foundry Profiles

| Profile | Use case |
|---|---|
| `default` | Standard development — optimizer on, 1k fuzz runs |
| `lite` | Fast iteration — optimizer off, 10 fuzz runs |
| `optimized` | Production builds — via_ir enabled, separate output |
| `test-optimized` | Test against optimized artifacts |

## Security

- All state-changing functions must have access control
- Use OpenZeppelin contracts for standard patterns
- Prefer `SafeERC20` for token transfers
- Check-effects-interactions pattern for reentrancy safety
- Use NatSpec `@notice` and `@dev` to document security assumptions

## References

@justfile
@package.json
@CONTRIBUTING.md
@foundry.toml
