#!/usr/bin/env bats
# print_config() output and the --print-config short-circuit.

load ../helpers/common
setup()    { load_libs; setup_update_env; }
teardown() { teardown_update_env; }

@test "print_config: shows both updaters and other effective values" {
    SYSTEM_UPDATER=pamac; AUR_UPDATER=pamac; AUR_RECENT_DAYS=9
    EXCLUDE_ALIEN=(brave-bin); KEEP_ORPHANS=(); LUA_ALLOWLIST=(mailspring)
    run print_config
    assert_success
    assert_output --partial "System updater     pamac"
    assert_output --partial "AUR updater        pamac"
    assert_output --partial "AUR_RECENT_DAYS    9"
    assert_output --partial "EXCLUDE_ALIEN      brave-bin"
    assert_output --partial "KEEP_ORPHANS       (none)"
}

@test "print_config marks the default updaters" {
    SYSTEM_UPDATER=pacman; AUR_UPDATER=yay
    run print_config
    assert_output --partial "System updater     pacman"
    assert_output --partial "AUR updater        yay"
    assert_output --partial "[default]"
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
    refute_output --partial "Cleaning caches"
    refute_output --partial "Updating packages"
}

@test "--print-config reflects CLI updater overrides" {
    run bash "$REPO_ROOT/update.sh" --no-config --system-updater pamac --aur-updater none --print-config
    assert_success
    assert_output --partial "System updater     pamac"
    assert_output --partial "AUR updater        none"
}
