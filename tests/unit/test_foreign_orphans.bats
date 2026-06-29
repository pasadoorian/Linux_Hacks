#!/usr/bin/env bats
# check_foreign_orphans(): EXCLUDE_ALIEN filtering + KEEP_ORPHANS protection +
# per-removal prompt.

load ../helpers/common
setup() {
    load_libs; setup_update_env
    export FX_QM_FILE="$TEST_HOME/qm.txt"
    export FX_ORPHANS_FILE="$TEST_HOME/orphans.txt"
    printf '%s\n' "brave-bin 1.0.0" "mailspring 1.2.0" "ghostpkg 3.0.0" > "$FX_QM_FILE"
    printf '%s\n' "orphan-a" "orphan-b" "keepme" > "$FX_ORPHANS_FILE"
}
teardown() { teardown_update_env; }

@test "EXCLUDE_ALIEN is filtered out of alien-pkgs.txt with a count" {
    EXCLUDE_ALIEN=(brave-bin); KEEP_ORPHANS=()
    run check_foreign_orphans <<< $'q\n'
    assert_output --partial "1 foreign package(s) suppressed by EXCLUDE_ALIEN"
    run cat "$USER_HOME/alien-pkgs.txt"
    refute_output --partial "brave-bin"
    assert_output --partial "mailspring"
    assert_output --partial "ghostpkg"
}

@test "KEEP_ORPHANS are protected and never offered for removal" {
    EXCLUDE_ALIEN=(); KEEP_ORPHANS=(keepme)
    run check_foreign_orphans <<< $'n\nn\n'
    assert_output --partial "Protected orphans (KEEP_ORPHANS): keepme"
    refute_output --partial "Remove orphan 'keepme'"
}

@test "answering y/n removes only the confirmed orphan" {
    EXCLUDE_ALIEN=(); KEEP_ORPHANS=(keepme)
    run check_foreign_orphans <<< $'y\nn\n'
    assert_output --partial "Removing: orphan-a"
    assert stub_called "pacman -Rsn --noconfirm orphan-a"
    refute_line --partial "pacman -Rsn --noconfirm orphan-a orphan-b"
}

@test "answering 'a' removes all remaining orphans" {
    EXCLUDE_ALIEN=(); KEEP_ORPHANS=(keepme)
    run check_foreign_orphans <<< $'a\n'
    assert stub_called "pacman -Rsn --noconfirm orphan-a orphan-b"
}

@test "answering 'q' quits without removing anything" {
    EXCLUDE_ALIEN=(); KEEP_ORPHANS=()
    run check_foreign_orphans <<< $'q\n'
    assert_output --partial "No orphans removed."
    refute_output --partial "Removing:"
}

@test "no orphans present is reported cleanly" {
    : > "$FX_ORPHANS_FILE"
    EXCLUDE_ALIEN=(); KEEP_ORPHANS=()
    run check_foreign_orphans <<< ''
    assert_output --partial "No orphaned packages found."
}
