# Shared bats helpers for the update.sh test suite.
# Source via `load helpers/common` (bats adds the .bash extension).

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
STUB_BIN="$TESTS_DIR/stubs/bin"
FIXTURES="$TESTS_DIR/fixtures"

# Pull in bats-support / bats-assert / bats-file (vendored submodules).
load_libs() {
    load "$TESTS_DIR/bats/bats-support/load"
    load "$TESTS_DIR/bats/bats-assert/load"
    load "$TESTS_DIR/bats/bats-file/load"
}

# Build a clean, isolated environment and source update.sh (functions + defaults
# only -- the source guard stops before arg parsing / main). Stubs shadow the
# real package tools via PATH.
setup_update_env() {
    export UPDATE_SH_TEST=1
    export SUDO_USER="${USER:-tester}"
    TEST_HOME="$(mktemp -d)"
    export USER_HOME="$TEST_HOME"
    export STUB_LOG="$TEST_HOME/stub.log"
    : > "$STUB_LOG"
    export PATH="$STUB_BIN:$PATH"

    # shellcheck source=/dev/null
    source "$REPO_ROOT/update.sh"

    # The script enables strict mode; relax it so bats internals and our
    # output-based assertions behave predictably across direct function calls.
    set +e +u +o pipefail

    # Point config-related paths inside the sandbox; tests set vars explicitly.
    SCRIPT_DIR="$REPO_ROOT"
    CONFIG_FILE="$TEST_HOME/.config/update.sh/config"
    YAY_ALLOWLIST_FILE="$TEST_HOME/.config/yay/allowlist.txt"
    AUR_STATE_DIR="$TEST_HOME/.cache/update-aur"
    AUR_MAINT_SNAPSHOT="$AUR_STATE_DIR/maintainers.json"
}

teardown_update_env() {
    [[ -n "${TEST_HOME:-}" && -d "$TEST_HOME" ]] && rm -rf "$TEST_HOME"
}

# True if the stub log contains the given (substring) command invocation.
stub_called() { grep -qF "$1" "$STUB_LOG"; }

# Write a fixture file, creating parent dirs.
write_fixture() { mkdir -p "$(dirname "$1")"; printf '%s\n' "${@:2}" > "$1"; }
