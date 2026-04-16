# See https://just.systems/man/en/settings.html
set allow-duplicate-recipes
set allow-duplicate-variables
set shell := ["bash", "-euo", "pipefail", "-c"]
set unstable

# ---------------------------------------------------------------------------- #
#                                   ENV VARS                                   #
# ---------------------------------------------------------------------------- #

export FOUNDRY_DISABLE_NIGHTLY_WARNING := "true"
# Generate fuzz seed that changes weekly to avoid burning through RPC allowance
export FOUNDRY_FUZZ_SEED := `echo $(($(date +%s) / 604800))`

# ---------------------------------------------------------------------------- #
#                                   CONSTANTS                                  #
# ---------------------------------------------------------------------------- #

GLOBS_CLEAN := "artifacts artifacts-* broadcast cache coverage docs out out-* typechain-types lcov.info"
GLOBS_PRETTIER := "\"**/*.{json,svg,yaml,yml}\""
GLOBS_SOLIDITY := "{scripts,src,tests}/**/*.sol"

# ---------------------------------------------------------------------------- #
#                                    SCRIPTS                                   #
# ---------------------------------------------------------------------------- #

default:
    @just --list

# Initial project setup
setup: install install-mdformat
    [ -f .env ] || cp .env.example .env

# Install Node.js dependencies
install *args:
    bun install {{ args }}
alias i := install

# Install mdformat with plugins
@install-mdformat:
    uv tool install mdformat --python 3.14 \
        --with mdformat-frontmatter \
        --with mdformat-gfm

# Clean build artifacts
clean:
    npx del-cli {{ GLOBS_CLEAN }}
alias c := clean

# ---------------------------------------------------------------------------- #
#                                    CHECKS                                    #
# ---------------------------------------------------------------------------- #

# Run all code checks
full-check:
    @echo ""
    @echo "→ Running mdformat-check..."
    @just mdformat-check
    @echo "✓ mdformat-check completed"
    @echo ""
    @echo "→ Running solhint-check..."
    @just solhint-check
    @echo "✓ solhint-check completed"
    @echo ""
    @echo "→ Running fmt-check..."
    @just fmt-check
    @echo "✓ fmt-check completed"
    @echo ""
    @echo "→ Running prettier-check..."
    @just prettier-check
    @echo "✓ prettier-check completed"
    @echo ""
    @echo "All code checks passed!"
alias fc := full-check

# Run all code fixes
full-write:
    @echo ""
    @echo "→ Running mdformat-write..."
    @just mdformat-write
    @echo "✓ mdformat-write completed"
    @echo ""
    @echo "→ Running solhint-write..."
    @just solhint-write
    @echo "✓ solhint-write completed"
    @echo ""
    @echo "→ Running fmt-write..."
    @just fmt-write
    @echo "✓ fmt-write completed"
    @echo ""
    @echo "→ Running prettier-write..."
    @just prettier-write
    @echo "✓ prettier-write completed"
    @echo ""
    @echo "All code fixes applied!"
alias fw := full-write

# Check code with Solhint
solhint-check globs=GLOBS_SOLIDITY:
    bunx solhint --cache "{{ globs }}"
alias sc := solhint-check

# Fix code with Solhint
solhint-write globs=GLOBS_SOLIDITY:
    bunx solhint --cache --fix --noPrompt "{{ globs }}"
alias sw := solhint-write

# Check code with Forge formatter
[group("foundry")]
fmt-check:
    forge fmt --check

# Fix code with Forge formatter
[group("foundry")]
fmt-write:
    forge fmt

# Check Prettier formatting
@prettier-check globs=GLOBS_PRETTIER:
    bunx prettier \
        --check \
        --cache \
        --log-level warn \
        --no-error-on-unmatched-pattern \
        {{ globs }}
alias pc := prettier-check

# Format using Prettier
@prettier-write globs=GLOBS_PRETTIER:
    bunx prettier \
        --write \
        --cache \
        --log-level warn \
        --no-error-on-unmatched-pattern \
        {{ globs }}
alias pw := prettier-write

# Check Markdown formatting with mdformat
@mdformat-check +paths=".":
    mdformat --check {{ paths }}
alias mc := mdformat-check

# Format Markdown files with mdformat
@mdformat-write +paths=".":
    mdformat {{ paths }}
alias mw := mdformat-write

# ---------------------------------------------------------------------------- #
#                                    FOUNDRY                                   #
# ---------------------------------------------------------------------------- #

# Build contracts
[group("foundry")]
build:
    forge build
alias b := build

# Build using optimized profile
[group("foundry")]
build-optimized *args:
    FOUNDRY_PROFILE=optimized \
        forge build --extra-output-files metadata {{ args }}
alias bo := build-optimized

# Run tests with optional arguments
[group("foundry")]
test *args:
    forge test {{ args }}
alias t := test

# Run Bulloak checks
[group("foundry")]
test-bulloak:
    bulloak check --skip-modifiers "./tests/**/*.tree"
alias tb := test-bulloak

# Run tests using lite profile (skips fork tests by default)
[group("foundry")]
test-lite *args="--nmt testFork":
    FOUNDRY_PROFILE=lite forge test {{ args }}
alias tl := test-lite

# Run tests using optimized profile
[group("foundry")]
test-optimized: build-optimized
    FOUNDRY_PROFILE=test-optimized forge test
alias to := test-optimized

# Dump code coverage to an html file
[group("foundry"), script("bash")]
coverage:
    if ! command -v genhtml >/dev/null 2>&1; then
        echo "✗ genhtml CLI not found"
        echo "Install it with Homebrew: https://formulae.brew.sh/formula/lcov"
        exit 1
    fi
    forge coverage --report lcov
    genhtml --branch-coverage --ignore-errors inconsistent --output-dir coverage lcov.info
alias cov := coverage

# Perform a gas report
[group("foundry")]
gas-report:
    forge test --gas-report
alias gr := gas-report

# ---------------------------------------------------------------------------- #
#                                  DEPLOYMENT                                  #
# ---------------------------------------------------------------------------- #

# Deploy contracts (deterministic via CREATE2)
deploy *args:
    FOUNDRY_PROFILE=optimized \
        forge script script/Deploy.s.sol \
        -vvv --broadcast {{ args }}

# Deploy contracts (non-deterministic)
deploy-non-deterministic *args:
    FOUNDRY_PROFILE=optimized \
        forge script script/Deploy.s.sol \
        -vvv --broadcast {{ args }}
