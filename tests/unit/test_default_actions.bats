#!/usr/bin/env bats
# apply_default_actions(): maps DEFAULT_ACTIONS tokens to DO_* flags.

load ../helpers/common
setup()    { load_libs; setup_update_env; }
teardown() { teardown_update_env; }

@test "apply_default_actions: maps known tokens to the right flags" {
    DEFAULT_ACTIONS=(clean update firmware)
    apply_default_actions
    assert_equal "$DO_CLEAN" true
    assert_equal "$DO_UPDATE" true
    assert_equal "$DO_FIRMWARE" true
    assert_equal "$DO_ORPHANS" false
    assert_equal "$DO_PACNEW" false
}

@test "apply_default_actions: 'all' sets RUN_ALL" {
    DEFAULT_ACTIONS=(all)
    apply_default_actions
    assert_equal "$RUN_ALL" true
}

@test "apply_default_actions: security tokens map to opt-in flags" {
    DEFAULT_ACTIONS=(aur-audit aur-scan kernel)
    apply_default_actions
    assert_equal "$DO_AUR_AUDIT" true
    assert_equal "$DO_AUR_SCAN" true
    assert_equal "$DO_KERNEL" true
}

@test "apply_default_actions: unknown token warns but does not abort" {
    DEFAULT_ACTIONS=(clean bogus-token)
    run apply_default_actions
    assert_success
    assert_output --partial "unknown action 'bogus-token'"
}
