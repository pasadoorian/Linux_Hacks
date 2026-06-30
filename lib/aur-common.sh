#!/usr/bin/env bash
# Shared AUR supply-chain helpers, sourced by update.sh and aur-precheck.sh.
# Pure function/definition file — no side effects beyond setting IOC defaults
# (only if the caller has not already defined them).

# --- IOC source configuration (overridable by the caller) --------------------
# Community IOC source: lenucksi/aur-malware-check. HEAD = repo default branch.
: "${AUR_IOC_RAW_BASE:=https://raw.githubusercontent.com/lenucksi/aur-malware-check/HEAD/data}"
# AUR_IOC_CAMPAIGNS is an array; default it only if undeclared.
if ! declare -p AUR_IOC_CAMPAIGNS >/dev/null 2>&1; then
    AUR_IOC_CAMPAIGNS=(aur-infected chaos-rat russian-spam)
fi

# --- Generic helpers ---------------------------------------------------------

# Return 0 if $1 matches any of the remaining args as an exact name or glob.
matches_any() {
    local name="$1"; shift
    local pat
    for pat in "$@"; do
        [[ -z "$pat" ]] && continue
        # shellcheck disable=SC2053  -- intentional glob match (RHS unquoted)
        [[ "$name" == $pat ]] && return 0
    done
    return 1
}

# --- AUR RPC + IOC fetchers --------------------------------------------------

# Query the AUR RPC v5 'info' endpoint for a list of packages. Uses POST so a
# large package set does not blow the URL-length limit. Echoes the JSON body
# (an object with a .results array), or '{}' on failure so callers can degrade.
aur_query_rpc() {
    local data=() p
    for p in "$@"; do
        data+=(--data-urlencode "arg[]=$p")
    done
    curl -fsS --max-time 30 "${data[@]}" \
        "https://aur.archlinux.org/rpc/v5/info" 2>/dev/null || echo '{}'
}

# Fetch the merged list of known-malicious AUR maintainer accounts (newline-
# separated). Empty on network failure (callers treat that as "no data").
aur_fetch_bad_accounts() {
    local c url
    for c in "${AUR_IOC_CAMPAIGNS[@]}"; do
        url="$AUR_IOC_RAW_BASE/campaigns/$c/accounts.json"
        curl -fsS --max-time 20 "$url" 2>/dev/null \
            | jq -r '.accounts // {} | keys[]' 2>/dev/null || true
    done | sort -u
}

# Fetch the merged list of known-malicious package names from all campaigns.
aur_fetch_bad_packages() {
    local c f url
    for c in "${AUR_IOC_CAMPAIGNS[@]}"; do
        for f in packages.txt packages-extra.txt; do
            url="$AUR_IOC_RAW_BASE/campaigns/$c/$f"
            curl -fsS --max-time 20 "$url" 2>/dev/null || true
        done
    done | grep -vE '^\s*(#|$)' | sort -u
}

# Fetch the merged list of malicious npm/bun package names from all campaigns.
aur_fetch_bad_npm() {
    local c url
    for c in "${AUR_IOC_CAMPAIGNS[@]}"; do
        url="$AUR_IOC_RAW_BASE/campaigns/$c/npm-packages.txt"
        curl -fsS --max-time 20 "$url" 2>/dev/null || true
    done | grep -vE '^\s*(#|$)' | sort -u
}
