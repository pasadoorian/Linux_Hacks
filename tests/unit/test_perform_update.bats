#!/usr/bin/env bats
# perform_update(): backend dispatch and the yay-missing guard.

load ../helpers/common
setup()    { load_libs; setup_update_env; }
teardown() { teardown_update_env; }

@test "pacman backend runs pacman -Syuu only" {
    UPDATER="pacman"
    run perform_update
    assert_success
    assert stub_called "pacman -Syuu"
    refute_line --partial "yay -Syu"
}

@test "yay backend refreshes repos with pacman then runs yay for AUR" {
    UPDATER="yay"
    run perform_update
    assert_success
    assert stub_called "pacman -Syuu --noconfirm"
    assert stub_called "yay -Syu"
}

@test "pamac backend runs pamac update via the original user" {
    UPDATER="pamac"
    run perform_update
    assert_success
    assert stub_called "pamac update"
}

@test "yay backend errors cleanly when yay is not installed" {
    UPDATER="yay"
    # Make `command -v yay` report missing for this call only.
    command() {
        if [[ "$1 $2" == "-v yay" ]]; then return 1; fi
        builtin command "$@"
    }
    run perform_update
    assert_failure
    assert_output --partial "yay not found"
    unset -f command
}
