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
# The -u update is two independent steps, each with its own tool:
#   SYSTEM_UPDATER -- official repos: "pacman" (default) or "pamac"
#   AUR_UPDATER    -- AUR packages:   "yay" (default), "pamac", or "none"
# Override per-run with --system-updater / --aur-updater. (Choosing "pamac" as the
# AUR updater means pamac manages repos too -- it is an all-in-one tool.)
SYSTEM_UPDATER="pacman"
AUR_UPDATER="yay"
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

# Shared terminal-output helpers (section/ok/warn/err/note/run_quiet/summary).
# shellcheck source=lib/output.sh
source "$UPDATE_SH_DIR/lib/output.sh"

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

# Output verbosity (set by -v/--verbose, -q/--quiet; --no-color disables color).
VERBOSE=false
QUIET=false

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
    printf '  %-18s %s%s\n' "System updater"  "$SYSTEM_UPDATER" "$([[ $SYSTEM_UPDATER == pacman ]] && echo '   [default]')"
    printf '  %-18s %s%s\n' "AUR updater"     "$AUR_UPDATER"    "$([[ $AUR_UPDATER == yay ]] && echo '   [default]')"
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
  -u, --update         Update official repos (via SYSTEM_UPDATER) then AUR (via
                       AUR_UPDATER). Defaults: repos=pacman, AUR=yay.
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

Updater selection (override the config for this run):
      --system-updater TOOL   Official repos via: pacman (default) | pamac
      --aur-updater TOOL      AUR via: yay (default) | pamac | none
                              (yay = with PKGBUILD review + supply-chain hooks;
                               pamac also manages repos; none skips AUR)
  -R, --auto-rebuild          Rebuild packages with outdated deps (with confirmation)

Output:
  -v, --verbose      Show full output from cache/mirror/firmware sub-commands
  -q, --quiet        Only show warnings and errors (suppress status/headers)
      --no-color     Disable colored output (also honors NO_COLOR)

Configuration (see update.conf.example):
      --config FILE  Use FILE instead of ~/.config/update.sh/config
      --no-config    Ignore the config file; use built-in defaults only
      --print-config Print the effective configuration and exit

Examples:
  $(basename "$0")           # Run all actions; AUR updated via yay (with review)
  $(basename "$0") -a        # Run all actions (explicit)
  $(basename "$0") -c -u     # Clean caches and update only (repos: pacman, AUR: yay)
  $(basename "$0") --clean   # Clean caches only
  $(basename "$0") -u --aur-updater none   # Update official repos only (no AUR)
  $(basename "$0") -u --aur-updater pamac  # Update repos + AUR via pamac
  $(basename "$0") -u --system-updater pamac  # Use pamac for repos, yay for AUR
  $(basename "$0") -A        # Audit AUR packages (metrics + maintainer changes)
  $(basename "$0") -S        # Scan AUR packages against live malware IOCs
  $(basename "$0") -A -S     # Audit then scan (recommended before any AUR upgrade)
  $(basename "$0") -r -R     # Check and rebuild packages needing rebuild
  $(basename "$0") -y -R     # Check and rebuild Python packages
  $(basename "$0") -k        # Manage kernels (list/install/remove)
EOF
}

# =============================================================================
# Core Functions
# =============================================================================
# Section headers + step counters are printed by run_action() in main(); the
# functions themselves only emit status (ok/warn/err/note) and findings.

clean_caches() {
    section "Cleaning caches"

    # Remove stale package database lock if present
    rm -f /var/lib/pacman/db.lck

    # Clear pacman cache (all uninstalled packages)
    run_quiet "pacman cache cleared" pacman -Scc --noconfirm || true

    # Clear pamac cache as the real user. pamac's AUR database is per-user, so
    # running it as root (this script auto-elevates) triggers a spurious
    # "Failed to synchronize AUR database" warning. '|| true' keeps a clean
    # hiccup from aborting the run under 'set -e'.
    run_quiet "pamac cache cleared" sudo -u "$SUDO_USER" pamac clean --no-confirm || true

    # Clear AUR/pamac build caches
    rm -rf "$USER_HOME/.cache/pamac"
    rm -rf "/var/tmp/pamac-build-$SUDO_USER"

    # Clear yay cache (if using yay)
    rm -rf "$USER_HOME/.cache/yay" 2>/dev/null || true

    # Clear paru cache (if using paru)
    rm -rf "$USER_HOME/.cache/paru" 2>/dev/null || true

    summary_add "caches cleaned"
}

# Two orthogonal checks in one section:
#   FOREIGN  = installed but not in any sync DB (pacman -Qm) -> AUR/manual installs.
#              Listed to ~/alien-pkgs.txt for review; never auto-removed. Vet them
#              with -A/-S; exclude vetted ones via EXCLUDE_ALIEN.
#   ORPHANED = installed as a dependency, now required by nothing (pacman -Qtdq).
#              Offered for removal (skipping KEEP_ORPHANS, prompting per item).
check_foreign_orphans() {
    section "Foreign & orphaned packages"

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
    note "Foreign (AUR/manual) packages saved to $USER_HOME/alien-pkgs.txt for review (vet with -A/-S)"
    (( excluded > 0 )) && note "$excluded foreign package(s) suppressed by EXCLUDE_ALIEN"

    # --- Orphans: protect KEEP_ORPHANS, then confirm each remaining removal ---
    local orphans=() removable=() protected=() op
    mapfile -t orphans < <(pacman -Qtdq 2>/dev/null || true)
    if ((${#orphans[@]} == 0)); then
        ok "No orphaned packages found."
        return 0
    fi
    for op in "${orphans[@]}"; do
        if matches_any "$op" "${KEEP_ORPHANS[@]}"; then
            protected+=("$op")
        else
            removable+=("$op")
        fi
    done
    ((${#protected[@]})) && note "Protected orphans (KEEP_ORPHANS): ${protected[*]}"
    if ((${#removable[@]} == 0)); then
        ok "No removable orphans after applying KEEP_ORPHANS."
        return 0
    fi

    note "Orphaned packages eligible for removal:"
    printf '    %s\n' "${removable[@]}"
    echo ""

    local to_remove=() ans all=false
    for op in "${removable[@]}"; do
        if $all; then to_remove+=("$op"); continue; fi
        read -r -p "  Remove orphan '$op'? [y/n/a=all/q=quit] " ans
        case "$ans" in
            y|Y) to_remove+=("$op") ;;
            a|A) all=true; to_remove+=("$op") ;;
            q|Q) break ;;
            *)   : ;;  # anything else = skip this one
        esac
    done

    if ((${#to_remove[@]})); then
        note "Removing: ${to_remove[*]}"
        # -Rsn: also remove now-unneeded deps and saved config (.pacsave).
        pacman -Rsn --noconfirm "${to_remove[@]}"
        summary_add "${#to_remove[@]} orphan(s) removed"
    else
        ok "No orphans removed."
    fi
}

perform_update() {
    section "Updating packages"

    # Refresh the mirrors list and select the fastest ones
    run_quiet "Mirrors refreshed" pacman-mirrors -f || true

    # pamac is an all-in-one tool: if it's the AUR updater it also drives the repos
    # (there is no clean "AUR only" pamac mode), so it does both in one pass.
    if [[ "$AUR_UPDATER" == pamac ]]; then
        [[ "$SYSTEM_UPDATER" != pamac ]] && \
            note "AUR updater is pamac, which manages repos too — using pamac for both."
        note "Updating repos + AUR via pamac..."
        sudo -u "$SUDO_USER" pamac update -a --enable-downgrade --force-refresh
        summary_add "packages updated (pamac: repos + AUR)"
        return 0
    fi

    # --- Official repos ---
    case "$SYSTEM_UPDATER" in
        pacman)
            note "Updating official repos (pacman)..."
            pacman -Syuu --noconfirm
            ;;
        pamac)
            note "Updating official repos (pamac)..."
            sudo -u "$SUDO_USER" pamac update --enable-downgrade --force-refresh
            ;;
    esac

    # --- AUR ---
    case "$AUR_UPDATER" in
        yay)
            # AUR builds must NOT run as root (sudo -u "$SUDO_USER"). -Sua upgrades
            # AUR packages only (repos already done above). The diff/edit menus
            # force review and honor ~/.config/yay/init.lua hooks before any build.
            if ! command -v yay >/dev/null 2>&1; then
                err "yay not found (AUR_UPDATER=yay). Install with: pamac build yay"
                note "Or set --aur-updater pamac (or none)."
                return 1
            fi
            echo ""
            note "Updating AUR packages (yay, with PKGBUILD review)..."
            sudo -u "$SUDO_USER" yay -Sua --devel --cleanafter \
                --answerdiff None --answeredit None --diffmenu=true --editmenu=true
            summary_add "packages updated (repos: $SYSTEM_UPDATER, AUR: yay)"
            next_step "Check AUR packages before the next build: $(basename "$0") -A -S"
            ;;
        none)
            note "Skipping AUR (AUR updater: none)."
            summary_add "packages updated (repos only, via $SYSTEM_UPDATER)"
            ;;
    esac
}

# Rebuild the given packages through the CONFIGURED backend, so rebuilds get the
# same PKGBUILD review + ~/.config/yay/init.lua supply-chain hooks (and yay's
# resumable build cache) as a normal update -- not a hardcoded 'pamac build'.
# yay --rebuild forces a build even when the version is unchanged (the soname /
# checkrebuild case). pacman can't build AUR, so that backend refuses.
rebuild_packages() {
    case "$AUR_UPDATER" in
        yay)
            sudo -u "$SUDO_USER" yay -S --rebuild \
                --answerdiff None --answeredit None --diffmenu=true --editmenu=true \
                -- "$@"
            ;;
        pamac)
            sudo -u "$SUDO_USER" pamac build "$@"
            ;;
        none)
            err "Cannot rebuild AUR packages: AUR updater is 'none'."
            note "Set --aur-updater yay (or pamac) to rebuild: $*"
            return 1
            ;;
    esac
}

# Library/ABI rebuild check: checkrebuild (rebuild-detector) finds packages that
# link a shared library (.so) which changed or vanished -- the general soname-bump
# case. Complemented by check_python_rebuilds for the Python-interpreter case.
check_rebuilds() {
    section "Rebuild check"

    # Get list of packages needing rebuild
    local rebuild_output
    rebuild_output=$(checkrebuild)

    if [[ -z "$rebuild_output" ]]; then
        ok "No packages need rebuilding."
        return 0
    fi

    # Display packages (this is content the user needs to see)
    note "Packages that may require a rebuild:"
    echo "$rebuild_output"

    # If auto-rebuild is enabled, prompt for confirmation
    if $AUTO_REBUILD; then
        local packages
        packages=$(echo "$rebuild_output" | awk '{print $2}')

        echo ""
        note "The following packages will be rebuilt:"
        echo "$packages"
        echo ""
        read -r -p "  Rebuild these packages? (y/n): " confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            note "Rebuilding packages..."
            if rebuild_packages $packages; then
                summary_add "rebuilt packages with outdated deps"
            else
                warn "Rebuild did not complete (see output above)."
            fi
        else
            note "Skipping rebuild."
        fi
    else
        summary_add "$(echo "$rebuild_output" | grep -c .) package(s) may need rebuilding"
        next_step "Rebuild them: $(basename "$0") -r -R"
    fi
}

# Python-version rebuild check: after the interpreter bumps (e.g. 3.11 -> 3.13),
# find packages still owning files under a stale /usr/lib/python3.OLD dir
# (pacman -Qoq). Catches pure-Python packages that checkrebuild (-r) misses
# because they have no broken .so link.
check_python_rebuilds() {
    section "Python rebuild check"

    # Get current Python version (e.g., "3.13")
    local current_version
    current_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    note "Current Python version: $current_version"

    # Find old Python directories in /usr/lib/
    local old_dirs
    old_dirs=$(ls -d /usr/lib/python3.* 2>/dev/null | grep -v "python${current_version}" || true)

    if [[ -z "$old_dirs" ]]; then
        ok "No old Python directories found; nothing to rebuild."
        return 0
    fi

    note "Found old Python directories:"
    echo "$old_dirs"
    echo ""

    # Query packages in old directories
    local all_packages=""
    for dir in $old_dirs; do
        local dir_packages
        dir_packages=$(pacman -Qoq "$dir" 2>/dev/null || true)
        if [[ -n "$dir_packages" ]]; then
            note "Packages with files in $dir:"
            echo "$dir_packages"
            echo ""
            all_packages="$all_packages $dir_packages"
        fi
    done

    # Remove duplicates and trim whitespace
    local unique_packages
    unique_packages=$(echo "$all_packages" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)

    if [[ -z "$unique_packages" ]]; then
        ok "No packages need rebuilding for the new Python version."
        return 0
    fi

    # If auto-rebuild is enabled, prompt for confirmation
    if $AUTO_REBUILD; then
        note "The following packages will be rebuilt for Python $current_version:"
        echo "$unique_packages" | tr ' ' '\n'
        echo ""
        read -r -p "  Rebuild these packages? (y/n): " confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            note "Rebuilding packages..."
            if rebuild_packages $unique_packages; then
                summary_add "rebuilt packages for Python $current_version"
            else
                warn "Rebuild did not complete (see output above)."
            fi
        else
            note "Skipping rebuild."
        fi
    else
        next_step "Rebuild for Python $current_version: $(basename "$0") -y -R"
    fi
}

check_pacnew() {
    section "Pacnew files"
    local pacnew
    pacnew=$(pacdiff -o 2>/dev/null || true)
    if [[ -z "$pacnew" ]]; then
        ok "No .pacnew files to merge."
        return 0
    fi
    note "Pacnew files needing attention:"
    echo "$pacnew"
    summary_add "$(echo "$pacnew" | grep -c .) .pacnew file(s) to merge"
    next_step "Merge them: pacdiff"
}

check_firmware() {
    section "Firmware"
    run_quiet "Firmware metadata refreshed" fwupdmgr refresh || true
    local fw
    if fw=$(fwupdmgr get-updates 2>/dev/null) && [[ -n "$fw" ]]; then
        note "Firmware updates available:"
        echo "$fw"
        summary_add "firmware updates available"
        next_step "Apply firmware updates: fwupdmgr update"
    else
        ok "No firmware updates available."
    fi
}

manage_kernels() {
    section "Kernel management"

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
    section "AUR audit"

    if ! command -v jq >/dev/null 2>&1; then
        err "jq is required for the AUR audit. Install with: pacman -S jq"
        return 1
    fi

    local foreign
    foreign=$(get_foreign_filtered)
    if [[ -z "$foreign" ]]; then
        ok "No foreign (AUR) packages installed (after EXCLUDE_ALIEN)."
        return 0
    fi
    ((${#EXCLUDE_ALIEN[@]})) && note "EXCLUDE_ALIEN active: ${EXCLUDE_ALIEN[*]}"

    mkdir -p "$AUR_STATE_DIR"
    local report="$USER_HOME/aur-audit.txt"
    local now; now=$(date +%s)

    # One batched RPC call for every installed foreign package.
    local results
    results=$(aur_query_rpc $foreign | jq -c '.results // []')

    if [[ "$results" == "[]" ]]; then
        err "AUR RPC returned no data (network issue or all packages gone from AUR)."
        note "check connectivity, or investigate that none resolve in the AUR."
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
    note "Full report saved to $report"
    summary_add "AUR audit written to $report"
}

aur_scan() {
    section "AUR supply-chain scan"

    local foreign
    foreign=$(get_foreign_filtered)
    if [[ -z "$foreign" ]]; then
        ok "No foreign (AUR) packages installed (after EXCLUDE_ALIEN)."
        return 0
    fi
    ((${#EXCLUDE_ALIEN[@]})) && note "EXCLUDE_ALIEN active: ${EXCLUDE_ALIEN[*]}"

    local findings=0

    # --- 1. Installed packages vs. known-malicious package list ----------------
    note "Checking installed AUR packages against malicious-package lists..."
    local bad_pkgs
    bad_pkgs=$(aur_fetch_bad_packages)
    if [[ -z "$bad_pkgs" ]]; then
        warn "could not fetch malicious-package lists (offline?)."
        note "Coverage this run is degraded; only npm-cache seed checks apply."
    else
        note "Loaded $(echo "$bad_pkgs" | wc -l) known-malicious package names."
        local hit
        while IFS= read -r fp; do
            if grep -qxF "$fp" <<<"$bad_pkgs"; then
                alert "COMPROMISED PACKAGE INSTALLED: $fp"
                findings=$((findings + 1))
            fi
        done <<<"$foreign"
    fi

    # --- 2. npm/bun/yarn/pnpm caches for the injected dependency names ---------
    note "Scanning JS package caches for injected dependencies..."
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
                alert "MALICIOUS JS PACKAGE TRACE: '$nm' under $d"
                findings=$((findings + 1))
            fi
        done
    done <<<"$bad_npm"

    # --- 3. Suspicious build logic in cached PKGBUILDs / .install hooks --------
    note "Scanning cached PKGBUILDs / install hooks for risky build logic..."
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
            warn "Review these build files (network-fetch or JS-install logic):"
            echo "$matches" | sed 's/^/      /'
            findings=$((findings + 1))
        fi
    done

    # --- 4. Host persistence / rootkit indicators (Atomic Arch payload) --------
    note "Checking host for persistence / rootkit indicators..."
    # eBPF rootkit hidden maps
    if ls /sys/fs/bpf/hidden_* >/dev/null 2>&1; then
        alert "eBPF hidden map present: /sys/fs/bpf/hidden_*"
        findings=$((findings + 1))
    fi
    # Trojaned sudo shim in user PATH (not pacman-owned)
    if [[ -e "$USER_HOME/.local/bin/sudo" ]]; then
        alert "Suspicious '$USER_HOME/.local/bin/sudo' shim present (PATH hijack)."
        findings=$((findings + 1))
    fi
    # systemd units matching the payload's restart signature
    local unit_hits
    unit_hits=$(grep -rlE 'Restart=always' /etc/systemd/system "$USER_HOME/.config/systemd/user" 2>/dev/null \
        | xargs -r grep -lE 'RestartSec=30' 2>/dev/null || true)
    if [[ -n "$unit_hits" ]]; then
        warn "Review systemd units (Restart=always + RestartSec=30 - payload signature):"
        echo "$unit_hits" | sed 's/^/      /'
        findings=$((findings + 1))
    fi

    echo ""
    if (( findings == 0 )); then
        ok "Scan complete: no indicators matched."
        note "(A clean result is not a guarantee - lists cover known campaigns only.)"
    else
        warn "Scan complete: $findings indicator group(s) flagged above - INVESTIGATE."
        summary_add "$findings AUR scan indicator(s) flagged — INVESTIGATE"
    fi
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    # Keep the yay tripwire allowlist in sync with the config (cheap, always).
    sync_lua_allowlist

    # Count the actions that will run so section() can show [n/total] progress.
    STEP_TOTAL=0; STEP_CUR=0
    { $RUN_ALL || $DO_CLEAN; }          && STEP_TOTAL=$((STEP_TOTAL + 1)) || true
    { $RUN_ALL || $DO_ORPHANS; }        && STEP_TOTAL=$((STEP_TOTAL + 1)) || true
    { $RUN_ALL || $DO_UPDATE; }         && STEP_TOTAL=$((STEP_TOTAL + 1)) || true
    { $RUN_ALL || $DO_REBUILDS; }       && STEP_TOTAL=$((STEP_TOTAL + 1)) || true
    { $RUN_ALL || $DO_PYTHON_REBUILD; } && STEP_TOTAL=$((STEP_TOTAL + 1)) || true
    { $RUN_ALL || $DO_PACNEW; }         && STEP_TOTAL=$((STEP_TOTAL + 1)) || true
    { $RUN_ALL || $DO_FIRMWARE; }       && STEP_TOTAL=$((STEP_TOTAL + 1)) || true
    $DO_AUR_AUDIT && STEP_TOTAL=$((STEP_TOTAL + 1)) || true
    $DO_AUR_SCAN  && STEP_TOTAL=$((STEP_TOTAL + 1)) || true
    $DO_KERNEL    && STEP_TOTAL=$((STEP_TOTAL + 1)) || true

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

    print_summary
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

# Back-compat: the old single 'UPDATER' config key is deprecated in favor of
# SYSTEM_UPDATER + AUR_UPDATER. Map it (with a warning) if a config still sets it.
if [[ -n "${UPDATER:-}" ]]; then
    warn "config: 'UPDATER' is deprecated — use SYSTEM_UPDATER + AUR_UPDATER. Mapping '$UPDATER'."
    case "$UPDATER" in
        yay)    SYSTEM_UPDATER="pacman"; AUR_UPDATER="yay" ;;
        pacman) SYSTEM_UPDATER="pacman"; AUR_UPDATER="none" ;;
        pamac)  SYSTEM_UPDATER="pamac";  AUR_UPDATER="pamac" ;;
        *)      warn "config: unknown UPDATER='$UPDATER' ignored." ;;
    esac
fi

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
        --system-updater)
            SYSTEM_UPDATER="${2:-}"
            shift 2
            ;;
        --aur-updater)
            AUR_UPDATER="${2:-}"
            shift 2
            ;;
        -R|--auto-rebuild)
            AUTO_REBUILD=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -q|--quiet)
            QUIET=true
            shift
            ;;
        --no-color)
            UPDATE_NO_COLOR=1; output_setup_colors
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

# Validate the updater selections (from config or CLI).
case "$SYSTEM_UPDATER" in
    pacman|pamac) ;;
    *) echo "Error: SYSTEM_UPDATER must be 'pacman' or 'pamac' (got '$SYSTEM_UPDATER')" >&2; exit 1 ;;
esac
case "$AUR_UPDATER" in
    yay|pamac|none) ;;
    *) echo "Error: AUR_UPDATER must be 'yay', 'pamac', or 'none' (got '$AUR_UPDATER')" >&2; exit 1 ;;
esac

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
