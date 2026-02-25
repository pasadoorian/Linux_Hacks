#!/bin/bash
set -euo pipefail

# Re-execute as root if not already
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

# Store original user's home directory for user-specific paths
USER_HOME="/home/$SUDO_USER"

# Action flags (all false by default)
DO_CLEAN=false
DO_ORPHANS=false
DO_UPDATE=false
DO_REBUILDS=false
DO_PYTHON_REBUILD=false
DO_PACNEW=false
DO_FIRMWARE=false
DO_KERNEL=false
RUN_ALL=false

# Modifier flags
USE_PACMAN=false
AUTO_REBUILD=false

# =============================================================================
# Helper Functions
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Manjaro Linux system update and maintenance script.

Options:
  -c, --clean          Clean package and build caches
  -o, --orphans        Check foreign packages and remove orphans
  -u, --update         Perform full system update (uses pamac by default)
  -r, --rebuilds       List packages that need rebuilding
  -y, --python-rebuild Check Python packages needing rebuild after version upgrade
  -p, --pacnew         List pacnew files needing attention
  -f, --firmware       Check for firmware updates
  -k, --kernel         Manage kernels (list, install, remove)
  -a, --all            Run all actions (default if no options given, excludes -k)
  -h, --help           Show this help message

Modifiers:
  -P, --pacman       Use pacman instead of pamac for updates (official repos only)
  -R, --auto-rebuild Rebuild packages with outdated dependencies (with confirmation)

Examples:
  $(basename "$0")           # Run all actions (pamac)
  $(basename "$0") -a        # Run all actions (explicit)
  $(basename "$0") -c -u     # Clean caches and update only
  $(basename "$0") --clean   # Clean caches only
  $(basename "$0") -u -P     # Update using pacman instead of pamac
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

    # Clear pamac cache
    pamac clean --no-confirm

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

    # List foreign (AUR) packages for manual review - do not auto-remove
    pamac list --foreign > "$USER_HOME/alien-pkgs.txt"
    echo "Foreign packages saved to $USER_HOME/alien-pkgs.txt for review"

    # Remove true orphans (packages not required by anything)
    sudo -u "$SUDO_USER" pamac remove --orphans --unneeded || true
}

perform_update() {
    print_section "Performing update..."

    # Refresh the mirrors list and select the fastest ones
    pacman-mirrors -f

    if $USE_PACMAN; then
        # Update using pacman (official repos only)
        echo "Using pacman for update..."
        pacman -Syuu
    else
        # Update using pamac as original user (AUR requires non-root)
        echo "Using pamac for update..."
        sudo -u "$SUDO_USER" pamac update -a --enable-downgrade --force-refresh
    fi
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
# Main Execution
# =============================================================================

main() {
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

    # Kernel management is intentionally excluded from --all
    # as it requires explicit user interaction and decision-making
    if $DO_KERNEL; then
        manage_kernels
    fi
}

# =============================================================================
# Argument Parsing
# =============================================================================

# If no arguments, run all
if [[ $# -eq 0 ]]; then
    RUN_ALL=true
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--clean)
            DO_CLEAN=true
            shift
            ;;
        -o|--orphans)
            DO_ORPHANS=true
            shift
            ;;
        -u|--update)
            DO_UPDATE=true
            shift
            ;;
        -r|--rebuilds)
            DO_REBUILDS=true
            shift
            ;;
        -y|--python-rebuild)
            DO_PYTHON_REBUILD=true
            shift
            ;;
        -p|--pacnew)
            DO_PACNEW=true
            shift
            ;;
        -f|--firmware)
            DO_FIRMWARE=true
            shift
            ;;
        -k|--kernel)
            DO_KERNEL=true
            shift
            ;;
        -a|--all)
            RUN_ALL=true
            shift
            ;;
        -P|--pacman)
            USE_PACMAN=true
            shift
            ;;
        -R|--auto-rebuild)
            AUTO_REBUILD=true
            shift
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
