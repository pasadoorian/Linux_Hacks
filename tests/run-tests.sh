#!/usr/bin/env bash
# Local test runner for the linux_hacks repo.
#   ./tests/run-tests.sh            # run everything
#   ./tests/run-tests.sh -v         # verbose bats output
#   ./tests/run-tests.sh -f NAME    # only bats files matching NAME
#
# Runs: bash -n + luac -p (always), shellcheck (if installed), the bats unit +
# lint suites, and the pure-lua hook tests. Exits non-zero if anything fails.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
BATS="$TESTS_DIR/bats/bats-core/bin/bats"

VERBOSE=""; FILTER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) VERBOSE="--print-output-on-failure --verbose-run"; shift ;;
        -f|--filter)  FILTER="$2"; shift 2 ;;
        -h|--help)    grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

cd "$REPO_ROOT"
fail=0
section() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# --- Ensure vendored bats is present -----------------------------------------
if [[ ! -x "$BATS" ]]; then
    section "Fetching vendored bats submodules"
    git -C "$REPO_ROOT" submodule update --init --recursive || {
        echo "Could not init bats submodules (network?)." >&2; exit 1; }
fi

# --- Static checks ------------------------------------------------------------
section "bash -n (syntax)"
for s in "$REPO_ROOT"/*.sh; do bash -n "$s" && echo "ok  $(basename "$s")" || fail=1; done

if command -v luac >/dev/null; then
    section "luac -p (lua syntax)"
    for l in "$REPO_ROOT"/*.lua; do luac -p "$l" && echo "ok  $(basename "$l")" || fail=1; done
fi

if command -v shellcheck >/dev/null; then
    section "shellcheck (-S error)"
    for s in "$REPO_ROOT"/*.sh; do shellcheck -S error "$s" && echo "ok  $(basename "$s")" || fail=1; done
else
    echo "(shellcheck not installed -- skipping; install with: pacman -S shellcheck)"
fi

# --- bats suites --------------------------------------------------------------
section "bats unit + lint suites"
bats_args=($VERBOSE)
[[ -n "$FILTER" ]] && bats_args+=(--filter "$FILTER")
"$BATS" "${bats_args[@]}" "$TESTS_DIR/unit" "$TESTS_DIR/lint" || fail=1

# --- lua hook tests -----------------------------------------------------------
if command -v lua >/dev/null; then
    section "lua hook tests"
    LUA_HOME="$(mktemp -d)"
    mkdir -p "$LUA_HOME/.config/yay"
    printf 'mailspring\n*-electron\n' > "$LUA_HOME/.config/yay/allowlist.txt"
    HOME="$LUA_HOME" lua "$TESTS_DIR/lua/test_yay_init.lua" || fail=1
    rm -rf "$LUA_HOME"
else
    echo "(lua not installed -- skipping hook tests)"
fi

section "Result"
if [[ $fail -eq 0 ]]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; fi
exit $fail
