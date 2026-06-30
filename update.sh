#!/bin/bash
set -euo pipefail

# Re-execute as root if not already. Skipped when the script is sourced (e.g.
# the test suite sources it to unit-test individual functions) or when
# UPDATE_SH_TEST is set, so neither path triggers sudo.
if [[ "${BASH_SOURCE[0]}" == "${0}" && $EUID -ne 0 && -z "${UPDATE_SH_TEST:-}" ]]; then
    exec sudo "$0" "$@"
fi

# Store original user's home directory for user-specific paths. Overridable so
# tests can point every user-path at a temporary HOME.
USER_HOME="${USER_HOME:-/home/${SUDO_USER:-$USER}}"

# Action flags (all false by default)
DO_CLEAN=false
DO_ORPHANS=false
DO_UPDATE=false
DO_REBUILDS=false
DO_PYTHON_REBUILD=false
DO_PACNEW=false
DO_FIRMWARE=false
DO_KERNEL=false
DO_AUR_AUDIT=false
DO_AUR_SCAN=false
RUN_ALL=false

# Modifier flags
# UPDATER selects the -u backend: "yay" (default, repos via pacman + AUR via yay),
# "pacman" (official repos only), or "pamac" (repos + AUR via pamac).
UPDATER="yay"
AUTO_REBUILD=false

# =============================================================================
# AUR Supply-Chain Configuration (Atomic Arch / June 2026 and related)
# =============================================================================

# Community IOC source: lenucksi/aur-malware-check. Fetched fresh on every scan
# so coverage tracks the latest disclosures. HEAD = repo default branch.
AUR_IOC_RAW_BASE="https://raw.githubusercontent.com/lenucksi/aur-malware-check/HEAD/data"
AUR_IOC_CAMPAIGNS=(aur-infected chaos-rat russian-spam)

# Per-user state for maintainer-change / re-adoption detection (the Atomic Arch
# tell). Snapshot of each package's AUR maintainer, diffed across runs.
AUR_STATE_DIR="$USER_HOME/.cache/update-aur"
AUR_MAINT_SNAPSHOT="$AUR_STATE_DIR/maintainers.json"

# Offline fallback so a failed fetch is never silently "all clear". The live
# fetch supersedes these; they only seed a scan when the network is unavailable.
AUR_SEED_BAD_NPM=(atomic-lockfile js-digest lockfile-js nextfile-js)

# Treat a PKGBUILD changed within this many days as "recently changed" (a signal
# to eyeball, not a verdict -- mirrors yay v13's last-modified hint).
AUR_RECENT_DAYS=21

# =============================================================================
# Config-file defaults (overridable by ~/.config/update.sh/config, then CLI)
# =============================================================================

# Directory holding the real update.sh (resolved through any ~/update.sh symlink)
# so we can find update.conf.example for first-run seeding.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# Directory of THIS file (works whether executed, symlinked, or sourced by tests)
# so the shared library resolves correctly in every context.
UPDATE_SH_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Shared AUR helpers (matches_any, aur_query_rpc, aur_fetch_bad_*). Also used by
# aur-precheck.sh / the yay hooks so the supply-chain logic has one home.
# shellcheck source=lib/aur-common.sh
source "$UPDATE_SH_DIR/lib/aur-common.sh"

# Live config file (sourced as root; see load_config for the safety gate).
CONFIG_FILE="$USER_HOME/.config/update.sh/config"

# Which checks run when no action flags are given (see update.conf.example for
# the full token list). kept conservative to match historical behavior.
DEFAULT_ACTIONS=(clean orphans update rebuilds python-rebuild pacnew firmware)

# Exclusion lists (exact names or shell globs). Empty by default.
EXCLUDE_ALIEN=()    # foreign pkgs suppressed from reports
KEEP_ORPHANS=()     # orphans never offered for removal
LUA_ALLOWLIST=(mailspring)  # pkgs allowlisted in the yay tripwire hook

# File the yay init.lua hook reads its allowlist from (we keep it in sync).
YAY_ALLOWLIST_FILE="$USER_HOME/.config/yay/allowlist.txt"

# Config control flags (set by --config/--no-config/--print-config pre-scan).
NO_CONFIG=false
PRINT_CONFIG=false

# Track whether the user named any action on the CLI; if not, DEFAULT_ACTIONS apply.
ACTIONS_SPECIFIED=false

# =============================================================================
# Helper Functions
# =============================================================================

# (matches_any lives in lib/aur-common.sh, sourced above.)

# Source the config file as root, with a safety gate (we are running as root, so
# a writable-by-others config would be a privilege-escalation hole). Auto-seeds
# the live config from the repo template on first run.
load_config() {
    local f="$CONFIG_FILE"

    if [[ ! -f "$f" && -f "$SCRIPT_DIR/update.conf.example" ]]; then
        mkdir -p "$(dirname "$f")"
        cp "$SCRIPT_DIR/update.conf.example" "$f"
        chown -R "$SUDO_USER:$SUDO_USER" "$USER_HOME/.config/update.sh" 2>/dev/null || true
        echo "Created default config at $f (from update.conf.example)."
    fi

    if [[ ! -f "$f" ]]; then
        echo "No config file at $f; using built-in defaults."
        return 0
    fi

    local owner perms
    owner=$(stat -c '%U' "$f")
    perms=$(stat -c '%a' "$f")
    if [[ "$owner" != "root" && "$owner" != "$SUDO_USER" ]]; then
        echo "WARNING: $f is owned by '$owner' (not root/$SUDO_USER); refusing to source it." >&2
        return 0
    fi
    if [[ "${perms: -1}" =~ [2367] ]]; then   # world-writable (other has 'w')
        echo "WARNING: $f is world-writable; refusing to source it. Fix with: chmod o-w '$f'" >&2
        return 0
    fi

    # shellcheck source=/dev/null
    source "$f"
}

# Expand DEFAULT_ACTIONS (config-defined) into the DO_* flags. Used only when no
# action flag was given on the command line.
apply_default_actions() {
    local a
    for a in "${DEFAULT_ACTIONS[@]}"; do
        case "$a" in
            clean)          DO_CLEAN=true ;;
            orphans)        DO_ORPHANS=true ;;
            update)         DO_UPDATE=true ;;
            rebuilds)       DO_REBUILDS=true ;;
            python-rebuild) DO_PYTHON_REBUILD=true ;;
            pacnew)         DO_PACNEW=true ;;
            firmware)       DO_FIRMWARE=true ;;
            kernel)         DO_KERNEL=true ;;
            aur-audit)      DO_AUR_AUDIT=true ;;
            aur-scan)       DO_AUR_SCAN=true ;;
            all)            RUN_ALL=true ;;
            *) echo "Config: ignoring unknown action '$a' in DEFAULT_ACTIONS." >&2 ;;
        esac
    done
}

# Print the effective configuration (defaults + config file + CLI overrides).
print_config() {
    echo "Effective configuration"
    echo "----------------------------------------------"
    printf '  %-18s %s\n' "config file"      "$($NO_CONFIG && echo "(skipped: --no-config)" || echo "$CONFIG_FILE")"
    printf '  %-18s %s\n' "UPDATER"          "$UPDATER"
    printf '  %-18s %s\n' "AUTO_REBUILD"     "$AUTO_REBUILD"
    printf '  %-18s %s\n' "AUR_RECENT_DAYS"  "$AUR_RECENT_DAYS"
    printf '  %-18s %s\n' "DEFAULT_ACTIONS"  "${DEFAULT_ACTIONS[*]:-(none)}"
    printf '  %-18s %s\n' "AUR_IOC_CAMPAIGNS" "${AUR_IOC_CAMPAIGNS[*]:-(none)}"
    printf '  %-18s %s\n' "EXCLUDE_ALIEN"    "${EXCLUDE_ALIEN[*]:-(none)}"
    printf '  %-18s %s\n' "KEEP_ORPHANS"     "${KEEP_ORPHANS[*]:-(none)}"
    printf '  %-18s %s\n' "LUA_ALLOWLIST"    "${LUA_ALLOWLIST[*]:-(none)}"
}

# Write LUA_ALLOWLIST to the file the yay init.lua hook reads, so the config
# stays the single source of truth for the tripwire allowlist.
sync_lua_allowlist() {
    local f="$YAY_ALLOWLIST_FILE"
    mkdir -p "$(dirname "$f")"
    if ((${#LUA_ALLOWLIST[@]})); then
        printf '%s\n' "${LUA_ALLOWLIST[@]}" > "$f"
    else
        : > "$f"
    fi
    chown -R "$SUDO_USER:$SUDO_USER" "$(dirname "$f")" 2>/dev/null || true
}

# Emit installed foreign (AUR) package names, one per line, with EXCLUDE_ALIEN
# entries filtered out. Shared by the AUR audit and scan.
get_foreign_filtered() {
    local fp
    while IFS= read -r fp; do
        [[ -z "$fp" ]] && continue
        matches_any "$fp" "${EXCLUDE_ALIEN[@]}" && continue
        echo "$fp"
    done < <(pacman -Qmq 2>/dev/null || true)
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Manjaro Linux system update and maintenance script.

Options:
  -c, --clean          Clean package and build caches
  -o, --orphans        Check foreign packages and remove orphans
  -u, --update         Perform full system update (repos via pacman + AUR via yay
                       by default; override with -P pacman-only or -m pamac)
  -r, --rebuilds       List packages that need rebuilding
  -y, --python-rebuild Check Python packages needing rebuild after version upgrade
  -p, --pacnew         List pacnew files needing attention
  -f, --firmware       Check for firmware updates
  -k, --kernel         Manage kernels (list, install, remove)
  -A, --aur-audit      (explicit-only) Per-AUR-package metrics: update age,
                       orphan status, maintainer-change/re-adoption detection,
                       out-of-date flag. Never runs as part of --all.
  -S, --aur-scan       (explicit-only) Scan installed AUR packages against live
                       supply-chain IOCs (Atomic Arch / June 2026 and related).
                       Never runs as part of --all.
  -a, --all            Run all actions (default if no options given;
                       excludes -k, -A, and -S)
  -h, --help           Show this help message

Modifiers (select the -u backend; default is yay):
  -Y, --yay          Repos via pacman + AUR via yay, review-enabled (DEFAULT)
  -P, --pacman       Official repos only via pacman (no AUR)
  -m, --pamac        Repos + AUR via pamac (the old default)
  -R, --auto-rebuild Rebuild packages with outdated dependencies (with confirmation)

Configuration (see update.conf.example):
      --config FILE  Use FILE instead of ~/.config/update.sh/config
      --no-config    Ignore the config file; use built-in defaults only
      --print-config Print the effective configuration and exit

Examples:
  $(basename "$0")           # Run all actions; AUR updated via yay (with review)
  $(basename "$0") -a        # Run all actions (explicit)
  $(basename "$0") -c -u     # Clean caches and update only (yay for AUR)
  $(basename "$0") --clean   # Clean caches only
  $(basename "$0") -u -P     # Update official repos only (pacman, no AUR)
  $(basename "$0") -u -m     # Update via pamac instead of yay
  $(basename "$0") -A        # Audit AUR packages (metrics + maintainer changes)
  $(basename "$0") -S        # Scan AUR packages against live malware IOCs
  $(basename "$0") -A -S     # Audit then scan (recommended before any AUR upgrade)
  $(basename "$0") -r -R     # Check and rebuild packages needing rebuild
  $(basename "$0") -y -R     # Check and rebuild Python packages
  $(basename "$0") -k        # Manage kernels (list/install/remove)
EOF
}

print_section() {
    echo "$1"
    echo "----------------------------------------------"
}

# =============================================================================
# Core Functions
# =============================================================================

clean_caches() {
    print_section "Cleaning Package and Build Caches..."

    # Remove stale package database lock if present
    rm -f /var/lib/pacman/db.lck

    # Clear pacman cache (all uninstalled packages)
    pacman -Scc --noconfirm

    # Clear pamac cache as the real user. pamac's AUR database is per-user, so
    # running it as root (this script auto-elevates) triggers a spurious
    # "Failed to synchronize AUR database" warning. '|| true' keeps a clean
    # hiccup from aborting the run under 'set -e'.
    sudo -u "$SUDO_USER" pamac clean --no-confirm || true

    # Clear AUR/pamac build caches
    rm -rf "$USER_HOME/.cache/pamac"
    rm -rf "/var/tmp/pamac-build-$SUDO_USER"

    # Clear yay cache (if using yay)
    rm -rf "$USER_HOME/.cache/yay" 2>/dev/null || true

    # Clear paru cache (if using paru)
    rm -rf "$USER_HOME/.cache/paru" 2>/dev/null || true

    # Optional: keep only one cached version of each package for rollback
    # paccache -rk1
}

check_foreign_orphans() {
    print_section "Checking for foreign and orphaned packages..."

    # --- Foreign (AUR) packages, minus EXCLUDE_ALIEN, saved for manual review ---
    local line name excluded=0
    : > "$USER_HOME/alien-pkgs.txt"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name=${line%% *}
        if matches_any "$name" "${EXCLUDE_ALIEN[@]}"; then
            excluded=$((excluded + 1))
            continue
        fi
        echo "$line" >> "$USER_HOME/alien-pkgs.txt"
    done < <(pacman -Qm 2>/dev/null || true)
    chown "$SUDO_USER:$SUDO_USER" "$USER_HOME/alien-pkgs.txt" 2>/dev/null || true
    echo "Foreign packages saved to $USER_HOME/alien-pkgs.txt for review"
    (( excluded > 0 )) && echo "  ($excluded foreign package(s) suppressed by EXCLUDE_ALIEN)"

    # --- Orphans: protect KEEP_ORPHANS, then confirm each remaining removal ---
    local orphans=() removable=() protected=() op
    mapfile -t orphans < <(pacman -Qtdq 2>/dev/null || true)
    if ((${#orphans[@]} == 0)); then
        echo "No orphaned packages found."
        return 0
    fi
    for op in "${orphans[@]}"; do
        if matches_any "$op" "${KEEP_ORPHANS[@]}"; then
            protected+=("$op")
        else
            removable+=("$op")
        fi
    done
    ((${#protected[@]})) && echo "Protected orphans (KEEP_ORPHANS): ${protected[*]}"
    if ((${#removable[@]} == 0)); then
        echo "No removable orphans after applying KEEP_ORPHANS."
        return 0
    fi

    echo "Orphaned packages eligible for removal:"
    printf '  %s\n' "${removable[@]}"
    echo ""

    local to_remove=() ans all=false
    for op in "${removable[@]}"; do
        if $all; then to_remove+=("$op"); continue; fi
        read -r -p "Remove orphan '$op'? [y/n/a=all/q=quit] " ans
        case "$ans" in
            y|Y) to_remove+=("$op") ;;
            a|A) all=true; to_remove+=("$op") ;;
            q|Q) break ;;
            *)   : ;;  # anything else = skip this one
        esac
    done

    if ((${#to_remove[@]})); then
        echo "Removing: ${to_remove[*]}"
        # -Rsn: also remove now-unneeded deps and saved config (.pacsave).
        pacman -Rsn --noconfirm "${to_remove[@]}"
    else
        echo "No orphans removed."
    fi
}

perform_update() {
    print_section "Performing update..."

    # Refresh the mirrors list and select the fastest ones
    pacman-mirrors -f

    case "$UPDATER" in
        yay)
            # DEFAULT. Official repos via pacman (run as root), then AUR via yay
            # as the original user. yay v13 surfaces PKGBUILD last-modified
            # timestamps and honors ~/.config/yay/init.lua hooks; the diff/edit
            # menus force a review of every PKGBUILD/diff before anything builds.
            # AUR builds must NOT run as root, hence sudo -u "$SUDO_USER".
            if ! command -v yay >/dev/null 2>&1; then
                echo "yay not found. Install with: pamac build yay"
                echo "  (or use -P for pacman-only, or -m for pamac)"
                return 1
            fi
            echo "Refreshing official repos with pacman..."
            pacman -Syuu --noconfirm
            echo ""
            echo "Updating AUR packages with yay (PKGBUILD review enabled)..."
            echo "Tip: run '$(basename "$0") -A -S' first to audit + scan before building."
            sudo -u "$SUDO_USER" yay -Syu --aur --devel \
                --combinedupgrade --cleanafter \
                --answerdiff None --answeredit None --diffmenu=true --editmenu=true
            ;;
        pacman)
            # Official repos only (no AUR)
            echo "Using pacman for update (official repos only)..."
            pacman -Syuu
            ;;
        pamac)
            # Update using pamac as original user (AUR requires non-root)
            echo "Using pamac for update..."
            sudo -u "$SUDO_USER" pamac update -a --enable-downgrade --force-refresh
            ;;
    esac
}

check_rebuilds() {
    print_section "The following packages may require a re-build:"

    # Get list of packages needing rebuild
    local rebuild_output
    rebuild_output=$(checkrebuild)

    if [[ -z "$rebuild_output" ]]; then
        echo "No packages need rebuilding."
        return 0
    fi

    # Display packages
    echo "$rebuild_output"

    # If auto-rebuild is enabled, prompt for confirmation
    if $AUTO_REBUILD; then
        local packages
        packages=$(echo "$rebuild_output" | awk '{print $2}')

        echo ""
        echo "The following packages will be rebuilt:"
        echo "$packages"
        echo ""
        read -r -p "Rebuild these packages? (y/n): " confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "Rebuilding packages..."
            sudo -u "$SUDO_USER" pamac build $packages
        else
            echo "Skipping rebuild."
        fi
    fi
}

check_python_rebuilds() {
    print_section "Checking for Python packages needing rebuild..."

    # Get current Python version (e.g., "3.13")
    local current_version
    current_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    echo "Current Python version: $current_version"

    # Find old Python directories in /usr/lib/
    local old_dirs
    old_dirs=$(ls -d /usr/lib/python3.* 2>/dev/null | grep -v "python${current_version}" || true)

    if [[ -z "$old_dirs" ]]; then
        echo "No old Python directories found. System is up to date."
        return 0
    fi

    echo "Found old Python directories:"
    echo "$old_dirs"
    echo ""

    # Query packages in old directories
    local all_packages=""
    for dir in $old_dirs; do
        local dir_packages
        dir_packages=$(pacman -Qoq "$dir" 2>/dev/null || true)
        if [[ -n "$dir_packages" ]]; then
            echo "Packages with files in $dir:"
            echo "$dir_packages"
            echo ""
            all_packages="$all_packages $dir_packages"
        fi
    done

    # Remove duplicates and trim whitespace
    local unique_packages
    unique_packages=$(echo "$all_packages" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)

    if [[ -z "$unique_packages" ]]; then
        echo "No packages need rebuilding for the new Python version."
        return 0
    fi

    # If auto-rebuild is enabled, prompt for confirmation
    if $AUTO_REBUILD; then
        echo "The following packages will be rebuilt for Python $current_version:"
        echo "$unique_packages" | tr ' ' '\n'
        echo ""
        read -r -p "Rebuild these packages? (y/n): " confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "Rebuilding packages..."
            sudo -u "$SUDO_USER" pamac build $unique_packages
        else
            echo "Skipping rebuild."
        fi
    fi
}

check_pacnew() {
    print_section "The following pacnew files may require attention:"
    pacdiff -o
}

check_firmware() {
    print_section "Checking for firmware updates with fwupd"
    fwupdmgr refresh
    fwupdmgr get-updates || echo "No firmware updates available."
}

manage_kernels() {
    print_section "Kernel Management"

    # Display currently installed kernels
    echo "Currently installed kernels:"
    echo ""
    mhwd-kernel -li
    echo ""

    # Display available kernels
    echo "Available kernels:"
    echo ""
    mhwd-kernel -l
    echo ""

    # Prompt for kernel installation
    read -r -p "Would you like to install a new kernel? (y/n): " install_confirm
    if [[ "$install_confirm" =~ ^[Yy]$ ]]; then
        echo ""
        echo "Enter the kernel version to install (e.g., 612 for linux612, 66 for linux66):"
        read -r -p "Kernel version: " kernel_version

        if [[ -z "$kernel_version" ]]; then
            echo "No kernel version specified. Skipping installation."
        else
            echo "Installing linux${kernel_version}..."
            mhwd-kernel -i "linux${kernel_version}"

            if [[ $? -eq 0 ]]; then
                echo ""
                echo "Kernel linux${kernel_version} installed successfully."
            fi
        fi
    fi

    echo ""

    # Prompt for kernel removal
    read -r -p "Would you like to remove an old kernel? (y/n): " remove_confirm
    if [[ "$remove_confirm" =~ ^[Yy]$ ]]; then
        echo ""
        echo "Currently installed kernels:"
        mhwd-kernel -li
        echo ""
        echo "Enter the kernel version to remove (e.g., 66 for linux66):"
        read -r -p "Kernel version to remove: " remove_version

        if [[ -z "$remove_version" ]]; then
            echo "No kernel version specified. Skipping removal."
        else
            # Get the currently running kernel version
            local running_kernel
            running_kernel=$(uname -r | sed 's/\([0-9]*\.[0-9]*\).*/\1/' | tr -d '.')

            if [[ "$remove_version" == "$running_kernel" ]]; then
                echo "Warning: Cannot remove the currently running kernel (linux${running_kernel})."
                echo "Please reboot into a different kernel first."
            else
                echo "Removing linux${remove_version}..."
                mhwd-kernel -r "linux${remove_version}"
            fi
        fi
    fi

    echo ""
    echo "Kernel management complete."
}

# =============================================================================
# AUR Audit & Supply-Chain Scan
# =============================================================================
# (aur_query_rpc + aur_fetch_bad_* live in lib/aur-common.sh, sourced above.)

aur_audit() {
    print_section "AUR audit: metrics + maintainer-change detection..."

    if ! command -v jq >/dev/null 2>&1; then
        echo "jq is required for the AUR audit. Install with: pacman -S jq"
        return 1
    fi

    local foreign
    foreign=$(get_foreign_filtered)
    if [[ -z "$foreign" ]]; then
        echo "No foreign (AUR) packages installed (after EXCLUDE_ALIEN)."
        return 0
    fi
    ((${#EXCLUDE_ALIEN[@]})) && echo "(EXCLUDE_ALIEN active: ${EXCLUDE_ALIEN[*]})"

    mkdir -p "$AUR_STATE_DIR"
    local report="$USER_HOME/aur-audit.txt"
    local now; now=$(date +%s)

    # One batched RPC call for every installed foreign package.
    local results
    results=$(aur_query_rpc $foreign | jq -c '.results // []')

    if [[ "$results" == "[]" ]]; then
        echo "AUR RPC returned no data (network issue or all packages gone from AUR)."
        echo "  - check connectivity, or investigate that none resolve in the AUR."
        return 1
    fi

    # Current maintainer snapshot { "pkg": "maintainer-or-null" } and the prior one.
    local cur_snapshot prev_snapshot="{}"
    cur_snapshot=$(echo "$results" | jq -c 'map({key: .Name, value: .Maintainer}) | from_entries')
    [[ -f "$AUR_MAINT_SNAPSHOT" ]] && prev_snapshot=$(cat "$AUR_MAINT_SNAPSHOT")

    {
        echo "AUR audit  -  $(date)"
        echo "Installed foreign packages: $(echo "$foreign" | wc -w)"
        echo ""
        printf '%-34s %-16s %7s %-8s %6s  %s\n' \
            "PACKAGE" "MAINTAINER" "AGE(d)" "OOD" "VOTES" "FLAGS"
        echo "------------------------------------------------------------------------------------------"
    } | tee "$report"

    # Per-package metrics, worst (oldest/flagged) first via sort on the age col.
    echo "$results" | jq -r --argjson now "$now" --argjson recent "$AUR_RECENT_DAYS" '
        .[] |
        ( ($now - .LastModified) / 86400 | floor ) as $age |
        [ .Name,
          (.Maintainer // "ORPHAN"),
          $age,
          (if .OutOfDate == null then "-" else "FLAGGED" end),
          (.NumVotes // 0),
          ( [ (if .Maintainer == null then "ORPHAN" else empty end),
              (if .OutOfDate != null then "OUT-OF-DATE" else empty end),
              (if $age <= $recent then "RECENTLY-CHANGED" else empty end)
            ] | join(" ") )
        ] | @tsv' \
    | while IFS=$'\t' read -r name maint age ood votes flags; do
        printf '%-34s %-16s %7s %-8s %6s  %s\n' \
            "$name" "${maint:0:16}" "$age" "$ood" "$votes" "$flags"
    done | tee -a "$report"

    # Installed but no longer present in the AUR (deleted/renamed) -> investigate.
    local present missing="" fp
    present=$(echo "$results" | jq -r '.[].Name')
    for fp in $foreign; do
        grep -qxF "$fp" <<<"$present" || missing+="$fp "
    done
    if [[ -n "$missing" ]]; then
        { echo ""; echo "NOT FOUND IN AUR (deleted/renamed - investigate): $missing"; } | tee -a "$report"
    fi

    # --- Maintainer-change / re-adoption detection (the Atomic Arch tell) ------
    { echo ""; echo "=== Maintainer changes since last run ==="; } | tee -a "$report"
    local changes
    changes=$(jq -rn --argjson prev "$prev_snapshot" --argjson cur "$cur_snapshot" '
        $cur | to_entries[]
        | .key as $k | .value as $v
        | select($prev | has($k))
        | (($prev[$k]) // null) as $old
        | select($old != ($v // null))
        | "\($k): \($old // "ORPHAN")  ->  \($v // "ORPHAN")"')
    if [[ -z "$changes" ]]; then
        echo "  none (or first run - baseline saved)" | tee -a "$report"
    else
        while IFS= read -r line; do
            echo "  [REVIEW BEFORE UPGRADE] $line"
        done <<<"$changes" | tee -a "$report"
    fi

    # Cross-reference current maintainers against known-malicious AUR accounts.
    local bad_accounts
    bad_accounts=$(aur_fetch_bad_accounts)
    if [[ -n "$bad_accounts" ]]; then
        local hits
        hits=$(echo "$results" | jq -r --arg bad "$bad_accounts" '
            ($bad | split("\n") | map(select(length>0))) as $b
            | .[] | select(.Maintainer != null and (.Maintainer as $m | $b | index($m)))
            | "\(.Name) (maintainer: \(.Maintainer))"')
        if [[ -n "$hits" ]]; then
            { echo ""; echo "!!! MAINTAINED BY A KNOWN-MALICIOUS ACCOUNT - REMOVE/INVESTIGATE NOW:"; } | tee -a "$report"
            echo "$hits" | sed 's/^/  /' | tee -a "$report"
        fi
    fi

    # Persist snapshot for next run's diff; keep state owned by the real user.
    echo "$cur_snapshot" > "$AUR_MAINT_SNAPSHOT"
    chown -R "$SUDO_USER:$SUDO_USER" "$AUR_STATE_DIR" 2>/dev/null || true
    chown "$SUDO_USER:$SUDO_USER" "$report" 2>/dev/null || true

    echo ""
    echo "Full report saved to $report"
}

aur_scan() {
    print_section "AUR supply-chain scan (live IOCs)..."

    local foreign
    foreign=$(get_foreign_filtered)
    if [[ -z "$foreign" ]]; then
        echo "No foreign (AUR) packages installed (after EXCLUDE_ALIEN)."
        return 0
    fi
    ((${#EXCLUDE_ALIEN[@]})) && echo "(EXCLUDE_ALIEN active: ${EXCLUDE_ALIEN[*]})"

    local findings=0

    # --- 1. Installed packages vs. known-malicious package list ----------------
    echo "[*] Checking installed AUR packages against malicious-package lists..."
    local bad_pkgs
    bad_pkgs=$(aur_fetch_bad_packages)
    if [[ -z "$bad_pkgs" ]]; then
        echo "    WARNING: could not fetch malicious-package lists (offline?)."
        echo "    Coverage this run is degraded; only npm-cache seed checks apply."
    else
        echo "    Loaded $(echo "$bad_pkgs" | wc -l) known-malicious package names."
        local hit
        while IFS= read -r fp; do
            if grep -qxF "$fp" <<<"$bad_pkgs"; then
                echo "    !!! COMPROMISED PACKAGE INSTALLED: $fp"
                findings=$((findings + 1))
            fi
        done <<<"$foreign"
    fi

    # --- 2. npm/bun/yarn/pnpm caches for the injected dependency names ---------
    echo "[*] Scanning JS package caches for injected dependencies..."
    local bad_npm
    bad_npm=$(aur_fetch_bad_npm)
    [[ -z "$bad_npm" ]] && bad_npm=$(printf '%s\n' "${AUR_SEED_BAD_NPM[@]}")
    local cache_dirs=(
        "$USER_HOME/.npm" "$USER_HOME/.bun" "$USER_HOME/.cache/yarn"
        "$USER_HOME/.local/share/pnpm" "$USER_HOME/.cache/pnpm"
    )
    local d nm
    while IFS= read -r nm; do
        [[ -z "$nm" ]] && continue
        for d in "${cache_dirs[@]}"; do
            [[ -d "$d" ]] || continue
            if find "$d" -maxdepth 6 -iname "*${nm}*" 2>/dev/null | grep -q .; then
                echo "    !!! MALICIOUS JS PACKAGE TRACE: '$nm' under $d"
                findings=$((findings + 1))
            fi
        done
    done <<<"$bad_npm"

    # --- 3. Suspicious build logic in cached PKGBUILDs / .install hooks --------
    echo "[*] Scanning cached PKGBUILDs / install hooks for risky build logic..."
    local pkgbuild_roots=(
        "$USER_HOME/.cache/yay" "$USER_HOME/.cache/paru"
        "$USER_HOME/.cache/pamac" "/var/tmp/pamac-build-$SUDO_USER"
    )
    local root
    for root in "${pkgbuild_roots[@]}"; do
        [[ -d "$root" ]] || continue
        local matches
        matches=$(grep -rIlE \
            '(npm|bun|pnpm|yarn)[[:space:]]+(install|add|i|x)|curl[^|]*\|[[:space:]]*(sh|bash)|wget[^|]*\|[[:space:]]*(sh|bash)' \
            "$root" 2>/dev/null \
            --include='PKGBUILD' --include='*.install' --include='*.sh' || true)
        if [[ -n "$matches" ]]; then
            echo "    Review these build files (network-fetch or JS-install logic):"
            echo "$matches" | sed 's/^/      /'
            findings=$((findings + 1))
        fi
    done

    # --- 4. Host persistence / rootkit indicators (Atomic Arch payload) --------
    echo "[*] Checking host for persistence / rootkit indicators..."
    # eBPF rootkit hidden maps
    if ls /sys/fs/bpf/hidden_* >/dev/null 2>&1; then
        echo "    !!! eBPF hidden map present: /sys/fs/bpf/hidden_*"
        findings=$((findings + 1))
    fi
    # Trojaned sudo shim in user PATH (not pacman-owned)
    if [[ -e "$USER_HOME/.local/bin/sudo" ]]; then
        echo "    !!! Suspicious '$USER_HOME/.local/bin/sudo' shim present (PATH hijack)."
        findings=$((findings + 1))
    fi
    # systemd units matching the payload's restart signature
    local unit_hits
    unit_hits=$(grep -rlE 'Restart=always' /etc/systemd/system "$USER_HOME/.config/systemd/user" 2>/dev/null \
        | xargs -r grep -lE 'RestartSec=30' 2>/dev/null || true)
    if [[ -n "$unit_hits" ]]; then
        echo "    Review systemd units (Restart=always + RestartSec=30 - payload signature):"
        echo "$unit_hits" | sed 's/^/      /'
        findings=$((findings + 1))
    fi

    echo ""
    if (( findings == 0 )); then
        echo "Scan complete: no indicators matched."
        echo "(A clean result is not a guarantee - lists cover known campaigns only.)"
    else
        echo "Scan complete: $findings indicator group(s) flagged above - INVESTIGATE."
    fi
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    # Keep the yay tripwire allowlist in sync with the config (cheap, always).
    sync_lua_allowlist

    if $RUN_ALL || $DO_CLEAN; then
        clean_caches
    fi

    if $RUN_ALL || $DO_ORPHANS; then
        check_foreign_orphans
    fi

    if $RUN_ALL || $DO_UPDATE; then
        perform_update
    fi

    if $RUN_ALL || $DO_REBUILDS; then
        check_rebuilds
    fi

    if $RUN_ALL || $DO_PYTHON_REBUILD; then
        check_python_rebuilds
    fi

    if $RUN_ALL || $DO_PACNEW; then
        check_pacnew
    fi

    if $RUN_ALL || $DO_FIRMWARE; then
        check_firmware
    fi

    # AUR security checks are explicit-only (never part of --all) so a routine
    # update run stays fast and non-interactive. Request them with -A / -S.
    if $DO_AUR_AUDIT; then
        aur_audit
    fi

    if $DO_AUR_SCAN; then
        aur_scan
    fi

    # Kernel management is intentionally excluded from --all
    # as it requires explicit user interaction and decision-making
    if $DO_KERNEL; then
        manage_kernels
    fi
}

# =============================================================================
# Argument Parsing
# =============================================================================

# When sourced (e.g. by the test suite) stop here: only the function definitions
# and default variables above are loaded -- no argument parsing, no main() run.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

# Pre-scan for config-control flags so the config is loaded (and possibly
# redirected) BEFORE the main parse, while CLI action flags still win over it.
_pre=("$@")
_i=0
while [[ $_i -lt ${#_pre[@]} ]]; do
    case "${_pre[$_i]}" in
        --no-config)    NO_CONFIG=true ;;
        --print-config) PRINT_CONFIG=true ;;
        --config)       _i=$((_i + 1)); CONFIG_FILE="${_pre[$_i]:-$CONFIG_FILE}" ;;
    esac
    _i=$((_i + 1))
done

$NO_CONFIG || load_config

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--clean)
            DO_CLEAN=true; ACTIONS_SPECIFIED=true
            shift
            ;;
        -o|--orphans)
            DO_ORPHANS=true; ACTIONS_SPECIFIED=true
            shift
            ;;
        -u|--update)
            DO_UPDATE=true; ACTIONS_SPECIFIED=true
            shift
            ;;
        -r|--rebuilds)
            DO_REBUILDS=true; ACTIONS_SPECIFIED=true
            shift
            ;;
        -y|--python-rebuild)
            DO_PYTHON_REBUILD=true; ACTIONS_SPECIFIED=true
            shift
            ;;
        -p|--pacnew)
            DO_PACNEW=true; ACTIONS_SPECIFIED=true
            shift
            ;;
        -f|--firmware)
            DO_FIRMWARE=true; ACTIONS_SPECIFIED=true
            shift
            ;;
        -k|--kernel)
            DO_KERNEL=true; ACTIONS_SPECIFIED=true
            shift
            ;;
        -A|--aur-audit)
            DO_AUR_AUDIT=true; ACTIONS_SPECIFIED=true
            shift
            ;;
        -S|--aur-scan)
            DO_AUR_SCAN=true; ACTIONS_SPECIFIED=true
            shift
            ;;
        -a|--all)
            RUN_ALL=true; ACTIONS_SPECIFIED=true
            shift
            ;;
        -P|--pacman)
            UPDATER="pacman"
            shift
            ;;
        -Y|--yay)
            UPDATER="yay"
            shift
            ;;
        -m|--pamac)
            UPDATER="pamac"
            shift
            ;;
        -R|--auto-rebuild)
            AUTO_REBUILD=true
            shift
            ;;
        # Config-control flags (already handled by the pre-scan above).
        --no-config|--print-config)
            shift
            ;;
        --config)
            shift 2   # flag + its value
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# No action named on the CLI -> fall back to the configured default set.
$ACTIONS_SPECIFIED || apply_default_actions

# --print-config short-circuits: show the merged settings and exit.
if $PRINT_CONFIG; then
    print_config
    exit 0
fi

main

# =============================================================================
# Notes
# =============================================================================

# Change this to reflect the outdated Python version and rebuild all packages that are affected:
# pamac build $(pacman -Qoq /usr/lib/python3.11)

# Note: When getting errors such as this:
# Error: Target not found: python-manjaro-sdk
# Likely these are packages that can be safely removed and have since been deprecated or replaced.
# Check the dependencies first using:
# pamac info python-manjaro-sdk
