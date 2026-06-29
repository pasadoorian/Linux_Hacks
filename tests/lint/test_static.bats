#!/usr/bin/env bats
# Static analysis + usage smoke tests for every script in the repo.

load ../helpers/common
setup() { load_libs; }

@test "all shell scripts parse (bash -n)" {
    for s in "$REPO_ROOT"/*.sh; do
        run bash -n "$s"
        assert_success
    done
}

@test "all lua files compile (luac -p)" {
    command -v luac >/dev/null || skip "luac not installed"
    for l in "$REPO_ROOT"/*.lua; do
        run luac -p "$l"
        assert_success
    done
}

@test "shellcheck reports no error-level issues (if installed)" {
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    for s in "$REPO_ROOT"/*.sh; do
        run shellcheck -S error "$s"
        assert_success
    done
}

@test "update.sh -h prints usage" {
    run env UPDATE_SH_TEST=1 SUDO_USER="$USER" timeout 10 bash "$REPO_ROOT/update.sh" -h
    assert_success
    assert_output --partial "Usage:"
}

@test "supply_chain_check.sh -h prints usage" {
    run timeout 10 bash "$REPO_ROOT/supply_chain_check.sh" -h
    assert_success
    assert_output --partial "Usage"
}

@test "mediabackup.sh -h prints usage" {
    run timeout 10 bash "$REPO_ROOT/mediabackup.sh" -h
    assert_success
    assert_output --partial "Usage"
}

@test "reset_audio.sh -h prints usage" {
    run timeout 10 bash "$REPO_ROOT/reset_audio.sh" -h
    assert_success
    assert_output --partial "Usage"
}

@test "bambu.sh -h prints usage" {
    run timeout 10 bash "$REPO_ROOT/bambu.sh" -h
    assert_success
    assert_output --partial "Usage"
}
