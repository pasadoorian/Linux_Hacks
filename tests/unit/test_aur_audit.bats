#!/usr/bin/env bats
# aur_audit(): metrics table, special lines, maintainer-change detection, and
# the known-malicious-account cross-reference.

load ../helpers/common

# Build an AUR RPC fixture with timestamps relative to "now" so the
# RECENTLY-CHANGED window is deterministic.
write_rpc_fixture() {
    local mnormal="${1:-alice}"
    local now old recent ood
    now=$(date +%s); old=$((now - 100 * 86400))
    recent=$((now - 2 * 86400)); ood=$((now - 50 * 86400))
    cat > "$FX_RPC_FILE" <<EOF
{ "results": [
  { "Name": "pkg-normal", "Maintainer": "$mnormal", "LastModified": $old,    "OutOfDate": null, "NumVotes": 100 },
  { "Name": "pkg-orphan", "Maintainer": null,        "LastModified": $old,    "OutOfDate": null, "NumVotes": 1 },
  { "Name": "pkg-ood",    "Maintainer": "bob",       "LastModified": $old,    "OutOfDate": $ood, "NumVotes": 5 },
  { "Name": "pkg-evil",   "Maintainer": "baduser",   "LastModified": $recent, "OutOfDate": null, "NumVotes": 2 }
] }
EOF
}

setup() {
    load_libs; setup_update_env
    export FX_FOREIGN_FILE="$TEST_HOME/foreign.txt"
    export FX_RPC_FILE="$TEST_HOME/rpc.json"
    export FX_ACCOUNTS_FILE="$FIXTURES/ioc/accounts.json"
    printf '%s\n' pkg-normal pkg-orphan pkg-ood pkg-evil ghostpkg > "$FX_FOREIGN_FILE"
    write_rpc_fixture alice
    EXCLUDE_ALIEN=()
}
teardown() { teardown_update_env; }

@test "audit prints a table and writes the report file" {
    run aur_audit
    assert_success
    assert_output --partial "AUR audit"
    assert_output --partial "pkg-normal"
    assert [ -f "$USER_HOME/aur-audit.txt" ]
    run cat "$USER_HOME/aur-audit.txt"
    assert_output --partial "pkg-ood"
}

@test "audit flags ORPHAN, OUT-OF-DATE and RECENTLY-CHANGED" {
    run aur_audit
    assert_output --partial "ORPHAN"
    assert_output --partial "OUT-OF-DATE"
    assert_output --partial "RECENTLY-CHANGED"
}

@test "audit lists packages no longer in the AUR" {
    run aur_audit
    assert_output --partial "NOT FOUND IN AUR"
    assert_output --partial "ghostpkg"
}

@test "audit flags a maintainer on the malicious-accounts list" {
    run aur_audit
    assert_output --partial "MAINTAINED BY A KNOWN-MALICIOUS ACCOUNT"
    assert_output --partial "pkg-evil (maintainer: baduser)"
}

@test "audit detects a maintainer change across runs" {
    aur_audit >/dev/null            # first run seeds the snapshot baseline
    write_rpc_fixture mallory        # pkg-normal changes alice -> mallory
    run aur_audit
    assert_output --partial "[REVIEW BEFORE UPGRADE] pkg-normal: alice  ->  mallory"
}

@test "first run reports no maintainer changes (baseline saved)" {
    run aur_audit
    assert_output --partial "none (or first run"
    assert [ -f "$AUR_MAINT_SNAPSHOT" ]
}

@test "EXCLUDE_ALIEN removes a package from the audit" {
    EXCLUDE_ALIEN=(pkg-evil)
    run aur_audit
    assert_output --partial "EXCLUDE_ALIEN active: pkg-evil"
    refute_output --partial "pkg-evil"
}

@test "audit fails cleanly when the RPC returns nothing (offline)" {
    CURL_FAIL=1 run aur_audit
    assert_failure
    assert_output --partial "AUR RPC returned no data"
}

@test "audit requires jq" {
    command() { if [[ "$1 $2" == "-v jq" ]]; then return 1; fi; builtin command "$@"; }
    run aur_audit
    assert_failure
    assert_output --partial "jq is required"
    unset -f command
}
