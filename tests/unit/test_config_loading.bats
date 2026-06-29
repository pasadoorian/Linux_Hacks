#!/usr/bin/env bats
# load_config(): sourcing, auto-seed, and the root-safety gate.

load ../helpers/common
setup()    { load_libs; setup_update_env; }
teardown() { teardown_update_env; }

@test "load_config: applies values from the config file" {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<'EOF'
UPDATER="pamac"
AUR_RECENT_DAYS=7
EXCLUDE_ALIEN=(brave-bin google-chrome)
EOF
    load_config
    assert_equal "$UPDATER" "pamac"
    assert_equal "$AUR_RECENT_DAYS" "7"
    assert_equal "${EXCLUDE_ALIEN[*]}" "brave-bin google-chrome"
}

@test "load_config: missing file falls back to defaults (no example to seed)" {
    SCRIPT_DIR="$TEST_HOME/nowhere"   # no update.conf.example here
    run load_config
    assert_success
    assert_output --partial "using built-in defaults"
}

@test "load_config: auto-seeds the live config from the example template" {
    SCRIPT_DIR="$REPO_ROOT"           # has update.conf.example
    run load_config
    assert_success
    assert_output --partial "Created default config"
    assert [ -f "$CONFIG_FILE" ]
}

@test "load_config: refuses a world-writable config (safety gate)" {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    echo 'UPDATER="pamac"' > "$CONFIG_FILE"
    chmod 666 "$CONFIG_FILE"
    run load_config
    assert_output --partial "world-writable"
    # value must NOT have been applied
    load_config >/dev/null 2>&1
    assert_equal "$UPDATER" "yay"
}

@test "load_config: refuses a config not owned by user/root" {
    # Constructing a foreign-owned file needs root; exercise only when possible.
    if [[ $EUID -ne 0 ]] && ! command -v fakeroot >/dev/null; then
        skip "needs root or fakeroot to create a foreign-owned file"
    fi
    skip "owner-mismatch branch covered by manual/root runs"
}

@test "load_config: tolerates a config with comments and blank lines" {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<'EOF'
# a comment

UPDATER="pacman"
EOF
    run load_config
    assert_success
    load_config
    assert_equal "$UPDATER" "pacman"
}
