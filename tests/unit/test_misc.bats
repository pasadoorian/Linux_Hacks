#!/usr/bin/env bats
# sync_lua_allowlist(), get_foreign_filtered(), clean_caches(), and the rebuild
# checks.

load ../helpers/common
setup()    { load_libs; setup_update_env; }
teardown() { teardown_update_env; }

@test "sync_lua_allowlist writes the configured list" {
    LUA_ALLOWLIST=(mailspring "*-electron")
    sync_lua_allowlist
    run cat "$YAY_ALLOWLIST_FILE"
    assert_line "mailspring"
    assert_line "*-electron"
}

@test "sync_lua_allowlist with an empty list yields an empty file" {
    LUA_ALLOWLIST=()
    sync_lua_allowlist
    assert [ -f "$YAY_ALLOWLIST_FILE" ]
    run cat "$YAY_ALLOWLIST_FILE"
    assert_output ""
}

@test "get_foreign_filtered honors EXCLUDE_ALIEN" {
    export FX_FOREIGN_FILE="$TEST_HOME/foreign.txt"
    printf '%s\n' brave-bin mailspring yay-git > "$FX_FOREIGN_FILE"
    EXCLUDE_ALIEN=(brave-bin "*-git")
    run get_foreign_filtered
    assert_output "mailspring"
}

@test "clean_caches invokes the cache tools and clears the user build cache" {
    mkdir -p "$USER_HOME/.cache/pamac/foo"
    run clean_caches
    assert stub_called "pacman -Scc"
    assert stub_called "pamac clean"
    assert [ ! -d "$USER_HOME/.cache/pamac" ]
}

@test "check_rebuilds lists packages and does not build without -R" {
    export FX_REBUILD_FILE="$TEST_HOME/rebuild.txt"
    printf '%s\n' "/usr/lib/foo libfoo" > "$FX_REBUILD_FILE"
    AUTO_REBUILD=false
    run check_rebuilds
    assert_output --partial "libfoo"
    refute_line --partial "pamac build"
}

@test "check_rebuilds with -R rebuilds via the configured backend (yay default)" {
    export FX_REBUILD_FILE="$TEST_HOME/rebuild.txt"
    printf '%s\n' "/usr/lib/foo libfoo" > "$FX_REBUILD_FILE"
    AUTO_REBUILD=true
    run check_rebuilds <<< $'y\n'
    assert stub_called "yay -S --rebuild"
    assert stub_called "libfoo"
    refute_line --partial "pamac build"
}

@test "rebuild_packages uses 'yay -S --rebuild' with review when AUR_UPDATER=yay" {
    AUR_UPDATER=yay
    run rebuild_packages libfoo libbar
    assert stub_called "yay -S --rebuild"
    assert stub_called "--diffmenu=true"
    assert stub_called "libfoo"
}

@test "rebuild_packages uses 'pamac build' when AUR_UPDATER=pamac" {
    AUR_UPDATER=pamac
    run rebuild_packages libfoo
    assert stub_called "pamac build libfoo"
}

@test "rebuild_packages refuses when AUR_UPDATER=none" {
    AUR_UPDATER=none
    run rebuild_packages libfoo
    assert_failure
    assert_output --partial "Cannot rebuild AUR packages: AUR updater is 'none'"
}

@test "check_rebuilds reports nothing to do on empty output" {
    export FX_REBUILD_FILE="$TEST_HOME/empty.txt"
    : > "$FX_REBUILD_FILE"
    run check_rebuilds
    assert_output --partial "No packages need rebuilding."
}
