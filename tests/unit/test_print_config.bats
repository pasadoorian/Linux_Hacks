#!/usr/bin/env bats
# print_config() output and the --print-config short-circuit.

load ../helpers/common
setup()    { load_libs; setup_update_env; }
teardown() { teardown_update_env; }

@test "print_config: shows effective values" {
    UPDATER="pamac"; AUR_RECENT_DAYS=9
    EXCLUDE_ALIEN=(brave-bin); KEEP_ORPHANS=(); LUA_ALLOWLIST=(mailspring)
    run print_config
    assert_success
    assert_output --partial "UPDATER            pamac"
    assert_output --partial "AUR_RECENT_DAYS    9"
    assert_output --partial "EXCLUDE_ALIEN      brave-bin"
    assert_output --partial "KEEP_ORPHANS       (none)"
}

@test "print_config: marks config as skipped under --no-config" {
    NO_CONFIG=true
    run print_config
    assert_output --partial "(skipped: --no-config)"
}

@test "--print-config short-circuits before running any action" {
    run bash "$REPO_ROOT/update.sh" --no-config --print-config
    assert_success
    assert_output --partial "Effective configuration"
    refute_output --partial "Cleaning Package"
    refute_output --partial "Performing update"
}

@test "--print-config reflects CLI override of the backend" {
    run bash "$REPO_ROOT/update.sh" --no-config -m -P --print-config
    assert_success
    assert_output --partial "UPDATER            pacman"   # last backend flag wins
}
