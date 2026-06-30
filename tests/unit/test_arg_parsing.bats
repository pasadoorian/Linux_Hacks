#!/usr/bin/env bats
# Argument parsing -> action dispatch (exercised end-to-end via subprocess, with
# all package tools stubbed). --no-config keeps these runs deterministic.

load ../helpers/common
setup()    { load_libs; setup_update_env; }
teardown() { teardown_update_env; }

@test "no action flag runs the default action set" {
    run bash "$REPO_ROOT/update.sh" --no-config
    assert_success
    assert_output --partial "Firmware"          # a DEFAULT_ACTIONS member
    refute_output --partial "AUR audit"         # -A is opt-in only
    refute_output --partial "Kernel management" # -k is opt-in only
}

@test "--all runs the default set but not the opt-in checks" {
    run bash "$REPO_ROOT/update.sh" --no-config --all
    assert_success
    assert_output --partial "Updating packages"
    refute_output --partial "AUR supply-chain scan"
}

@test "a single action runs only that section" {
    run bash "$REPO_ROOT/update.sh" --no-config -f
    assert_success
    assert_output --partial "Firmware"
    refute_output --partial "Updating packages"
}

@test "an updater flag alone still runs the default actions" {
    run bash "$REPO_ROOT/update.sh" --no-config --aur-updater none
    assert_success
    assert_output --partial "Updating packages"
    assert stub_called "pacman -Syuu"   # repos still via pacman (default); AUR skipped
}

@test "an invalid --aur-updater value is rejected" {
    run bash "$REPO_ROOT/update.sh" --no-config --aur-updater bogus --print-config
    assert_failure
    assert_output --partial "AUR_UPDATER must be"
}

@test "a legacy UPDATER config key is mapped with a deprecation warning" {
    local cfg="$TEST_HOME/legacy.conf"
    echo 'UPDATER=pamac' > "$cfg"
    run bash "$REPO_ROOT/update.sh" --config "$cfg" --print-config
    assert_success
    assert_output --partial "deprecated"
    assert_output --partial "System updater     pamac"
    assert_output --partial "AUR updater        pamac"
}

@test "unknown option exits non-zero with usage" {
    run bash "$REPO_ROOT/update.sh" --no-config --bogus
    assert_failure
    assert_output --partial "Unknown option"
    assert_output --partial "Usage:"
}

@test "-h prints usage and exits 0" {
    run bash "$REPO_ROOT/update.sh" -h
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "--aur-audit"
}

@test "-A is opt-in and not part of the default run" {
    run bash "$REPO_ROOT/update.sh" --no-config -A
    assert_success
    assert_output --partial "AUR audit"
    refute_output --partial "Updating packages"
}
