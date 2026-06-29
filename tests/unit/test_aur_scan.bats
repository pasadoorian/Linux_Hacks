#!/usr/bin/env bats
# aur_scan(): installed-package IOC match, JS-cache traces, risky build logic,
# host-persistence indicators, and the offline degraded path.

load ../helpers/common
setup() {
    load_libs; setup_update_env
    export FX_FOREIGN_FILE="$TEST_HOME/foreign.txt"
    export FX_PKGS_FILE="$FIXTURES/ioc/packages.txt"
    export FX_NPM_FILE="$FIXTURES/ioc/npm-packages.txt"
    printf '%s\n' evil-pkg good-pkg > "$FX_FOREIGN_FILE"
}
teardown() { teardown_update_env; }

@test "scan flags an installed package on the malicious list" {
    run aur_scan
    assert_success
    assert_output --partial "COMPROMISED PACKAGE INSTALLED: evil-pkg"
}

@test "scan flags a malicious JS package trace in a cache dir" {
    : > "$USER_HOME/.npm/atomic-lockfile" || { mkdir -p "$USER_HOME/.npm"; : > "$USER_HOME/.npm/atomic-lockfile"; }
    run aur_scan
    assert_output --partial "MALICIOUS JS PACKAGE TRACE"
    assert_output --partial "atomic-lockfile"
}

@test "scan flags risky build logic in a cached PKGBUILD" {
    mkdir -p "$USER_HOME/.cache/yay/evilpkg"
    printf '%s\n' "build() { npm install some-dep; }" > "$USER_HOME/.cache/yay/evilpkg/PKGBUILD"
    run aur_scan
    assert_output --partial "Review these build files"
    assert_output --partial "PKGBUILD"
}

@test "scan flags a trojaned sudo shim in the user PATH" {
    mkdir -p "$USER_HOME/.local/bin"; : > "$USER_HOME/.local/bin/sudo"
    run aur_scan
    assert_output --partial "Suspicious"
    assert_output --partial ".local/bin/sudo"
}

@test "scan flags a systemd unit with the payload restart signature" {
    mkdir -p "$USER_HOME/.config/systemd/user"
    printf '%s\n' "[Service]" "Restart=always" "RestartSec=30" \
        > "$USER_HOME/.config/systemd/user/evil.service"
    run aur_scan
    assert_output --partial "Review systemd units"
}

@test "scan reports a findings count when indicators match" {
    run aur_scan
    assert_output --partial "indicator group(s) flagged"
}

@test "offline scan degrades but still checks the seed npm list" {
    mkdir -p "$USER_HOME/.bun"; : > "$USER_HOME/.bun/atomic-lockfile"
    CURL_FAIL=1 run aur_scan
    assert_output --partial "could not fetch malicious-package lists"
    assert_output --partial "MALICIOUS JS PACKAGE TRACE"   # via AUR_SEED_BAD_NPM
}

@test "a clean foreign set yields no package/JS findings" {
    printf '%s\n' good-pkg > "$FX_FOREIGN_FILE"
    run aur_scan
    refute_output --partial "COMPROMISED PACKAGE INSTALLED"
    refute_output --partial "MALICIOUS JS PACKAGE TRACE"
}
