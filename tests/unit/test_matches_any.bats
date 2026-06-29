#!/usr/bin/env bats
# matches_any(): exact + glob matching used by all exclusion lists.

load ../helpers/common
setup()    { load_libs; setup_update_env; }
teardown() { teardown_update_env; }

@test "matches_any: exact name matches" {
    run matches_any "mailspring" mailspring brave-bin
    assert_success
}

@test "matches_any: non-match returns failure" {
    run matches_any "signal-desktop" mailspring brave-bin
    assert_failure
}

@test "matches_any: prefix glob matches" {
    run matches_any "python-foo" "python-*"
    assert_success
}

@test "matches_any: suffix glob matches" {
    run matches_any "yay-git" "*-git"
    assert_success
}

@test "matches_any: glob does not over-match" {
    run matches_any "python3" "python-*"
    assert_failure
}

@test "matches_any: empty pattern list never matches (set -u safe)" {
    local empty=()
    run matches_any "anything" "${empty[@]}"
    assert_failure
}

@test "matches_any: blank patterns are skipped" {
    run matches_any "foo" "" "bar"
    assert_failure
}
