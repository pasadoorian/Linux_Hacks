#!/usr/bin/env bats
# Output/UX behavior: summary, step counters, --quiet, --no-color, run_quiet.

load ../helpers/common
setup()    { load_libs; setup_update_env; }
teardown() { teardown_update_env; }

@test "a normal run prints a Summary section with next steps" {
    run bash "$REPO_ROOT/update.sh" --no-config -c
    assert_success
    assert_output --partial "Summary"
}

@test "section headers show a [n/total] step counter" {
    run bash "$REPO_ROOT/update.sh" --no-config -c
    assert_output --partial "[1/1]"
    assert_output --partial "Cleaning caches"
}

@test "--quiet suppresses section headers and status lines" {
    run bash "$REPO_ROOT/update.sh" --no-config -q -c
    assert_success
    refute_output --partial "▸"
    refute_output --partial "Summary"
}

@test "--no-color emits no ANSI escape sequences" {
    run bash "$REPO_ROOT/update.sh" --no-config --no-color -c
    assert_success
    refute_output --partial $'\033'
}

@test "run_quiet shows a one-line status on success" {
    run bash "$REPO_ROOT/update.sh" --no-config -c
    assert_output --partial "pacman cache cleared"
}

@test "run_quiet streams full output under --verbose" {
    # The pacman stub logs to STUB_LOG; under -v the command runs attached.
    run bash "$REPO_ROOT/update.sh" --no-config -v -c
    assert_success
    assert stub_called "pacman -Scc"
}
