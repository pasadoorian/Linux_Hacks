#!/usr/bin/env bats
# perform_update(): two-phase dispatch on SYSTEM_UPDATER + AUR_UPDATER.

load ../helpers/common
setup()    { load_libs; setup_update_env; }
teardown() { teardown_update_env; }

@test "default (pacman repos + yay AUR): pacman -Syuu then yay -Sua" {
    SYSTEM_UPDATER=pacman; AUR_UPDATER=yay
    run perform_update
    assert_success
    assert stub_called "pacman -Syuu --noconfirm"
    assert stub_called "yay -Sua"
}

@test "AUR_UPDATER=none updates repos only (no AUR helper)" {
    SYSTEM_UPDATER=pacman; AUR_UPDATER=none
    run perform_update
    assert_success
    assert stub_called "pacman -Syuu"
    assert_output --partial "Skipping AUR"
    run cat "$STUB_LOG"
    refute_output --partial "yay -Sua"
    refute_output --partial "pamac update"
}

@test "AUR_UPDATER=pamac uses pamac for repos+AUR in one pass (coerced)" {
    SYSTEM_UPDATER=pacman; AUR_UPDATER=pamac
    run perform_update
    assert_success
    assert_output --partial "pamac, which manages repos too"
    assert stub_called "pamac update -a"
    run cat "$STUB_LOG"
    refute_output --partial "pacman -Syuu"
}

@test "SYSTEM_UPDATER=pamac with yay AUR: pamac repos then yay AUR" {
    SYSTEM_UPDATER=pamac; AUR_UPDATER=yay
    run perform_update
    assert_success
    assert stub_called "pamac update"
    assert stub_called "yay -Sua"
}

@test "yay AUR errors cleanly when yay is not installed" {
    SYSTEM_UPDATER=pacman; AUR_UPDATER=yay
    command() { if [[ "$1 $2" == "-v yay" ]]; then return 1; fi; builtin command "$@"; }
    run perform_update
    assert_failure
    assert_output --partial "yay not found"
    unset -f command
}
