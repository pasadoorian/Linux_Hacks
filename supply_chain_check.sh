#!/bin/bash
#
# supply_chain_check.sh - Linux Supply Chain Validation Script
# Author: Paul Asadoorian (paul@psw.io)
#
# Based on Eclypsium's Linux Supply Chain Validation Cheat Sheet
# https://eclypsium.com/blog/linux-supply-chain-validation-cheat-sheet/
#
# Performs comprehensive security validation of firmware, boot chain,
# and package integrity on Linux systems.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Script configuration
VERBOSE=false
QUIET=false
RUN_ALL=false
SELECTED_CHECKS=()

# Available check categories
declare -A CHECK_CATEGORIES=(
    ["secureboot"]="Secure Boot status and configuration"
    ["bios"]="BIOS/UEFI version and information"
    ["firmware"]="Firmware security checks (requires chipsec)"
    ["fwupd"]="Firmware update status via fwupd"
    ["intel-me"]="Intel Management Engine status"
    ["microcode"]="CPU microcode version and vulnerabilities"
    ["tpm"]="TPM device validation"
    ["packages"]="Package integrity verification"
    ["hardware"]="Hardware inventory and details"
    ["storage"]="Storage device firmware"
)

usage() {
    cat <<EOF
${BOLD}Usage:${NC} $(basename "$0") [OPTIONS] [CHECKS...]

${BOLD}Linux Supply Chain Validation Script${NC}
Performs security validation of firmware, boot chain, and package integrity.

${BOLD}Options:${NC}
    -a, --all            Run all available checks
    -l, --list           List available check categories
    -v, --verbose        Show verbose output including raw command output
    -q, --quiet          Suppress informational messages
    -h, --help           Show this help message

${BOLD}Check Categories:${NC}
    secureboot    Secure Boot status and configuration
    bios          BIOS/UEFI version and information
    firmware      Firmware security checks (requires chipsec)
    fwupd         Firmware update status via fwupd
    intel-me      Intel Management Engine status
    microcode     CPU microcode version and vulnerabilities
    tpm           TPM device validation
    packages      Package integrity verification
    hardware      Hardware inventory and details
    storage       Storage device firmware

${BOLD}Examples:${NC}
    $(basename "$0") --all              # Run all checks
    $(basename "$0") secureboot bios    # Run specific checks
    $(basename "$0") -v packages        # Verbose package check
    $(basename "$0") --list             # Show available checks

${BOLD}Note:${NC} Many checks require root privileges. Run with sudo for full results.
EOF
}

list_checks() {
    echo -e "${BOLD}Available Check Categories:${NC}"
    echo ""
    for key in "${!CHECK_CATEGORIES[@]}"; do
        printf "  ${CYAN}%-12s${NC} %s\n" "$key" "${CHECK_CATEGORIES[$key]}"
    done | sort
    echo ""
}

# Logging functions
log() {
    if [[ "$QUIET" != true ]]; then
        echo -e "$*"
    fi
}

log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${DIM}$*${NC}"
    fi
}

print_header() {
    local title="$1"
    local width=70
    echo ""
    echo -e "${BLUE}$(printf '═%.0s' $(seq 1 $width))${NC}"
    echo -e "${BOLD}${BLUE}  $title${NC}"
    echo -e "${BLUE}$(printf '═%.0s' $(seq 1 $width))${NC}"
}

print_section() {
    local title="$1"
    echo ""
    echo -e "${CYAN}── $title ──${NC}"
}

print_status() {
    local label="$1"
    local value="$2"
    local status="${3:-info}"  # info, ok, warn, error

    case "$status" in
        ok)     echo -e "  ${GREEN}✓${NC} ${BOLD}$label:${NC} $value" ;;
        warn)   echo -e "  ${YELLOW}⚠${NC} ${BOLD}$label:${NC} ${YELLOW}$value${NC}" ;;
        error)  echo -e "  ${RED}✗${NC} ${BOLD}$label:${NC} ${RED}$value${NC}" ;;
        *)      echo -e "  ${BOLD}$label:${NC} $value" ;;
    esac
}

print_result() {
    local output="$1"
    if [[ -n "$output" ]]; then
        echo "$output" | sed 's/^/    /'
    else
        echo -e "    ${DIM}(no output)${NC}"
    fi
}

check_command() {
    local cmd="$1"
    command -v "$cmd" &>/dev/null
}

check_root() {
    [[ $EUID -eq 0 ]]
}

run_cmd() {
    local cmd="$1"
    local output
    local exit_code=0

    log_verbose "Running: $cmd"
    output=$(eval "$cmd" 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 && "$VERBOSE" == true ]]; then
        echo -e "    ${DIM}(command exited with code $exit_code)${NC}"
    fi

    echo "$output"
}

# ============================================================================
# CHECK: Secure Boot
# ============================================================================
check_secureboot() {
    print_header "SECURE BOOT VALIDATION"

    print_section "Secure Boot State (mokutil)"
    if check_command mokutil; then
        local sb_state
        sb_state=$(mokutil --sb-state 2>&1) || true
        if echo "$sb_state" | grep -qi "enabled"; then
            print_status "Secure Boot" "Enabled" "ok"
        elif echo "$sb_state" | grep -qi "disabled"; then
            print_status "Secure Boot" "Disabled" "warn"
        else
            print_status "Secure Boot" "$sb_state" "info"
        fi
        if [[ "$VERBOSE" == true ]]; then
            print_result "$sb_state"
        fi
    else
        print_status "mokutil" "Not installed" "warn"
    fi

    print_section "Boot Control Status (bootctl)"
    if check_command bootctl; then
        local bootctl_out
        bootctl_out=$(bootctl status 2>&1) || true
        if [[ "$VERBOSE" == true ]]; then
            print_result "$bootctl_out"
        else
            # Extract key information
            echo "$bootctl_out" | grep -E '(Secure Boot|Setup Mode|Boot Loader|Product)' | head -10 | sed 's/^/    /'
        fi
    else
        print_status "bootctl" "Not installed (systemd-boot)" "info"
    fi
}

# ============================================================================
# CHECK: BIOS/UEFI
# ============================================================================
check_bios() {
    print_header "BIOS/UEFI INFORMATION"

    if ! check_root; then
        print_status "Warning" "Run as root for complete BIOS information" "warn"
    fi

    print_section "BIOS Version and Date"
    if check_command dmidecode; then
        local bios_version bios_date bios_vendor
        bios_vendor=$(sudo dmidecode -s bios-vendor 2>/dev/null) || bios_vendor="Unknown"
        bios_version=$(sudo dmidecode -s bios-version 2>/dev/null) || bios_version="Unknown"
        bios_date=$(sudo dmidecode -s bios-release-date 2>/dev/null) || bios_date="Unknown"

        print_status "Vendor" "$bios_vendor"
        print_status "Version" "$bios_version"
        print_status "Release Date" "$bios_date"

        if [[ "$VERBOSE" == true ]]; then
            print_section "Full BIOS Details (dmidecode -t 0)"
            local full_bios
            full_bios=$(sudo dmidecode -t 0 2>/dev/null) || true
            print_result "$full_bios"
        fi
    else
        print_status "dmidecode" "Not installed" "error"
    fi

    print_section "Machine/Motherboard Info"
    if check_command inxi; then
        local machine_info
        machine_info=$(inxi -M 2>/dev/null) || true
        print_result "$machine_info"
    else
        print_status "inxi" "Not installed" "warn"
    fi

    if [[ "$VERBOSE" == true ]] && check_command hwinfo; then
        print_section "Hardware BIOS Info (hwinfo)"
        local hwinfo_out
        hwinfo_out=$(sudo hwinfo --bios 2>/dev/null | head -50) || true
        print_result "$hwinfo_out"
    fi

    if [[ "$VERBOSE" == true ]] && check_command lshw; then
        print_section "Firmware Details (lshw)"
        local lshw_out
        lshw_out=$(sudo lshw 2>/dev/null | grep -A8 '\*-firmware') || true
        print_result "$lshw_out"
    fi
}

# ============================================================================
# CHECK: Firmware Security (Chipsec)
# ============================================================================
check_firmware() {
    print_header "FIRMWARE SECURITY (CHIPSEC)"

    local chipsec_path=""
    # Look for chipsec in common locations
    for path in "/opt/chipsec" "$HOME/chipsec" "/usr/share/chipsec" "$(pwd)/chipsec"; do
        if [[ -f "$path/chipsec_main.py" ]]; then
            chipsec_path="$path"
            break
        fi
    done

    if [[ -z "$chipsec_path" ]]; then
        print_status "Chipsec" "Not found - install from https://github.com/chipsec/chipsec" "warn"
        echo ""
        echo -e "    ${DIM}Chipsec checks would include:${NC}"
        echo -e "    ${DIM}- Intel ME manufacturing mode verification${NC}"
        echo -e "    ${DIM}- SPI flash write protection status${NC}"
        echo -e "    ${DIM}- Comprehensive firmware security audit${NC}"
        return
    fi

    print_status "Chipsec Path" "$chipsec_path" "ok"

    if ! check_root; then
        print_status "Warning" "Chipsec requires root privileges" "error"
        return
    fi

    print_section "Intel ME Manufacturing Mode"
    local me_mode
    me_mode=$(sudo python3 "$chipsec_path/chipsec_main.py" -m common.me_mfg_mode 2>&1) || true
    if echo "$me_mode" | grep -qi "passed"; then
        print_status "ME Manufacturing Mode" "Disabled (PASSED)" "ok"
    elif echo "$me_mode" | grep -qi "failed"; then
        print_status "ME Manufacturing Mode" "Enabled (FAILED)" "error"
    fi
    if [[ "$VERBOSE" == true ]]; then
        print_result "$me_mode"
    fi

    print_section "BIOS Write Protection"
    local bios_wp
    bios_wp=$(sudo python3 "$chipsec_path/chipsec_main.py" -m common.bios_wp 2>&1) || true
    if echo "$bios_wp" | grep -qi "passed"; then
        print_status "BIOS Write Protection" "Enabled (PASSED)" "ok"
    elif echo "$bios_wp" | grep -qi "failed"; then
        print_status "BIOS Write Protection" "Disabled (FAILED)" "error"
    fi
    if [[ "$VERBOSE" == true ]]; then
        print_result "$bios_wp"
    fi

    if [[ "$VERBOSE" == true ]]; then
        print_section "Full Chipsec Security Audit"
        echo -e "    ${DIM}Running comprehensive check (this may take a while)...${NC}"
        local full_audit
        full_audit=$(sudo python3 "$chipsec_path/chipsec_main.py" 2>&1 | tail -30) || true
        print_result "$full_audit"
    fi
}

# ============================================================================
# CHECK: Firmware Updates (fwupd)
# ============================================================================
check_fwupd() {
    print_header "FIRMWARE UPDATE STATUS (FWUPD)"

    if ! check_command fwupdmgr; then
        print_status "fwupd" "Not installed" "error"
        return
    fi

    print_section "Devices with Firmware"
    local devices
    devices=$(fwupdmgr get-devices --no-unreported-check 2>/dev/null) || true
    if [[ "$VERBOSE" == true ]]; then
        print_result "$devices"
    else
        # Show summary of devices
        echo "$devices" | grep -E '(^[A-Za-z]|Device ID|Current version|Vendor)' | head -30 | sed 's/^/    /'
    fi

    print_section "Available Updates"
    local updates
    updates=$(fwupdmgr get-updates --no-unreported-check 2>&1) || true
    if echo "$updates" | grep -qi "no updates"; then
        print_status "Firmware Updates" "System is up to date" "ok"
    else
        print_status "Firmware Updates" "Updates available" "warn"
        print_result "$updates"
    fi

    print_section "Security Attributes"
    local security
    security=$(fwupdmgr security --force 2>&1) || true
    if [[ "$VERBOSE" == true ]]; then
        print_result "$security"
    else
        # Show HSI score and key items
        echo "$security" | grep -E '(HSI:|✔|✘|Host Security ID)' | head -20 | sed 's/^/    /'
    fi
}

# ============================================================================
# CHECK: Intel Management Engine
# ============================================================================
check_intel_me() {
    print_header "INTEL MANAGEMENT ENGINE"

    # Check for Intel ME detection tool
    local me_tool=""
    for path in "/opt/intel_csme" "$HOME/intel_csme" "$(pwd)/intel_csme"; do
        if [[ -f "$path/intel_csme_version_detection_tool" ]]; then
            me_tool="$path/intel_csme_version_detection_tool"
            break
        fi
    done

    print_section "ME Version via MEI"
    if [[ -r /dev/mei0 ]] || [[ -r /dev/mei ]]; then
        print_status "MEI Device" "Present" "ok"
        # Try to get ME version from sysfs
        if [[ -r /sys/class/mei/mei0/fw_ver ]]; then
            local fw_ver
            fw_ver=$(cat /sys/class/mei/mei0/fw_ver 2>/dev/null)
            print_status "ME Firmware Version" "$fw_ver"
        fi
    else
        print_status "MEI Device" "Not accessible (may need mei_me module)" "warn"
    fi

    if [[ -n "$me_tool" ]]; then
        print_section "Intel CSME Version Detection Tool"
        local me_output
        me_output=$(sudo python3 "$me_tool" 2>&1) || true
        print_result "$me_output"
    else
        echo ""
        echo -e "    ${DIM}Intel CSME version detection tool not found.${NC}"
        echo -e "    ${DIM}Download from Intel for detailed ME analysis.${NC}"
    fi

    # Check lspci for ME controller
    print_section "ME Controller (lspci)"
    if check_command lspci; then
        local me_pci
        me_pci=$(lspci 2>/dev/null | grep -i "management engine\|MEI\|HECI") || true
        if [[ -n "$me_pci" ]]; then
            print_result "$me_pci"
        else
            echo -e "    ${DIM}No ME controller found in lspci${NC}"
        fi
    fi
}

# ============================================================================
# CHECK: CPU Microcode
# ============================================================================
check_microcode() {
    print_header "CPU MICROCODE"

    print_section "CPU Information"
    if [[ -r /proc/cpuinfo ]]; then
        local cpu_info
        cpu_info=$(head -n7 /proc/cpuinfo)
        print_result "$cpu_info"

        # Extract microcode version
        local ucode_ver
        ucode_ver=$(grep -m1 "microcode" /proc/cpuinfo | awk '{print $3}')
        if [[ -n "$ucode_ver" ]]; then
            print_status "Microcode Version" "$ucode_ver" "ok"
        fi
    fi

    print_section "CPU Vulnerabilities"
    if [[ -d /sys/devices/system/cpu/vulnerabilities ]]; then
        for vuln in /sys/devices/system/cpu/vulnerabilities/*; do
            local name status
            name=$(basename "$vuln")
            status=$(cat "$vuln" 2>/dev/null)
            if echo "$status" | grep -qi "not affected\|mitigat"; then
                print_status "$name" "$status" "ok"
            else
                print_status "$name" "$status" "warn"
            fi
        done
    fi

    if check_command inxi; then
        print_section "Detailed CPU Info (inxi)"
        local inxi_cpu
        inxi_cpu=$(sudo inxi -C -a 2>/dev/null) || true
        print_result "$inxi_cpu"
    fi

    if [[ "$VERBOSE" == true ]]; then
        print_section "Microcode Boot Log"
        local ucode_log
        ucode_log=$(sudo journalctl --no-hostname -o short-monotonic --boot -0 2>/dev/null | grep -i 'microcode' | head -10) || true
        if [[ -n "$ucode_log" ]]; then
            print_result "$ucode_log"
        else
            echo -e "    ${DIM}No microcode messages in boot log${NC}"
        fi
    fi
}

# ============================================================================
# CHECK: TPM
# ============================================================================
check_tpm() {
    print_header "TPM VALIDATION"

    print_section "TPM Device"
    if [[ -c /dev/tpm0 ]] || [[ -c /dev/tpmrm0 ]]; then
        print_status "TPM Device" "Present (/dev/tpm0)" "ok"
    else
        print_status "TPM Device" "Not found" "warn"
    fi

    # Check TPM version from sysfs
    if [[ -d /sys/class/tpm/tpm0 ]]; then
        if [[ -r /sys/class/tpm/tpm0/tpm_version_major ]]; then
            local tpm_ver
            tpm_ver=$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null)
            print_status "TPM Version" "$tpm_ver.x"
        fi
    fi

    print_section "TPM DMI Information"
    if check_command dmidecode && check_root; then
        local tpm_dmi
        tpm_dmi=$(sudo dmidecode -t 43 2>/dev/null) || true
        if [[ -n "$tpm_dmi" ]] && ! echo "$tpm_dmi" | grep -qi "not present"; then
            print_result "$tpm_dmi"
        else
            echo -e "    ${DIM}No TPM information in DMI tables${NC}"
        fi
    fi

    # Check for tpm-vuln-checker
    local tpm_checker=""
    for path in "/opt/tpm-vuln-checker" "$HOME/tpm-vuln-checker" "$(pwd)/tpm-vuln-checker"; do
        if [[ -f "$path/tpm-vuln-checker" ]]; then
            tpm_checker="$path/tpm-vuln-checker"
            break
        fi
    done

    if [[ -n "$tpm_checker" ]]; then
        print_section "TPM Vulnerability Check"
        local vuln_out
        vuln_out=$(sudo "$tpm_checker" check 2>&1) || true
        print_result "$vuln_out"
    else
        echo ""
        echo -e "    ${DIM}tpm-vuln-checker not found.${NC}"
        echo -e "    ${DIM}Install from https://github.com/google/tpm-vuln-checker${NC}"
    fi

    # Try tpm2_getcap if available
    if check_command tpm2_getcap; then
        print_section "TPM2 Capabilities"
        local tpm2_info
        tpm2_info=$(tpm2_getcap properties-fixed 2>/dev/null | head -20) || true
        if [[ -n "$tpm2_info" ]]; then
            print_result "$tpm2_info"
        fi
    fi
}

# ============================================================================
# CHECK: Package Integrity
# ============================================================================
check_packages() {
    print_header "PACKAGE INTEGRITY"

    local distro=""
    if [[ -f /etc/os-release ]]; then
        distro=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    fi

    print_status "Detected Distribution" "$distro"

    case "$distro" in
        arch|manjaro|endeavouros)
            print_section "Pacman Package Verification"

            if check_command paccheck; then
                echo -e "    ${DIM}Running paccheck --sha256sum (this may take a while)...${NC}"
                local paccheck_out
                paccheck_out=$(sudo paccheck --sha256sum --quiet 2>&1 | head -50) || true
                if [[ -z "$paccheck_out" ]]; then
                    print_status "Package Integrity" "All packages verified" "ok"
                else
                    print_status "Package Integrity" "Issues found" "error"
                    print_result "$paccheck_out"
                fi
            elif check_command pacman; then
                # Fallback to pacman -Qkk
                echo -e "    ${DIM}Running pacman -Qkk (checking file presence)...${NC}"
                local modified
                modified=$(pacman -Qkk 2>&1 | grep -v "0 altered files" | head -20) || true
                if [[ -z "$modified" ]]; then
                    print_status "Package Files" "No alterations detected" "ok"
                else
                    print_status "Package Files" "Modified files found" "warn"
                    print_result "$modified"
                fi
            fi
            ;;

        debian|ubuntu|linuxmint|pop)
            print_section "Dpkg Package Verification"

            if check_command debsums; then
                echo -e "    ${DIM}Running debsums (this may take a while)...${NC}"
                local debsums_out
                debsums_out=$(sudo debsums 2>&1 | grep -v "OK$" | head -50) || true
                if [[ -z "$debsums_out" ]]; then
                    print_status "Package Integrity" "All packages verified" "ok"
                else
                    print_status "Package Integrity" "Issues found" "warn"
                    print_result "$debsums_out"
                fi
            else
                print_status "debsums" "Not installed (apt install debsums)" "warn"
                # Fallback to dpkg --verify
                echo -e "    ${DIM}Running dpkg --verify...${NC}"
                local dpkg_out
                dpkg_out=$(sudo dpkg --verify 2>&1 | head -30) || true
                if [[ -z "$dpkg_out" ]]; then
                    print_status "Package Files" "No issues detected" "ok"
                else
                    print_result "$dpkg_out"
                fi
            fi
            ;;

        rhel|centos|fedora|rocky|alma)
            print_section "RPM Package Verification"
            echo -e "    ${DIM}Running rpm -Va (this may take a while)...${NC}"
            local rpm_out
            rpm_out=$(sudo rpm -Va 2>&1 | head -50) || true
            if [[ -z "$rpm_out" ]]; then
                print_status "Package Integrity" "All packages verified" "ok"
            else
                print_status "Package Integrity" "Modified files found" "warn"
                print_result "$rpm_out"
            fi
            ;;

        *)
            print_status "Package Verification" "Unknown distribution: $distro" "warn"
            echo -e "    ${DIM}Supported: Arch/Manjaro, Debian/Ubuntu, RHEL/Fedora${NC}"
            ;;
    esac
}

# ============================================================================
# CHECK: Hardware Inventory
# ============================================================================
check_hardware() {
    print_header "HARDWARE INVENTORY"

    if check_command inxi; then
        print_section "System Summary"
        local sys_info
        sys_info=$(sudo inxi -b 2>/dev/null) || true
        print_result "$sys_info"

        print_section "Memory Modules"
        local mem_info
        mem_info=$(sudo inxi -m -a 2>/dev/null) || true
        print_result "$mem_info"

        if [[ "$VERBOSE" == true ]]; then
            print_section "PCI Slots"
            local slots_info
            slots_info=$(sudo inxi --slots -a 2>/dev/null) || true
            print_result "$slots_info"
        fi
    fi

    print_section "PCI Devices"
    if check_command lspci; then
        local pci_out
        if [[ "$VERBOSE" == true ]]; then
            pci_out=$(sudo lspci -nnmmvkD 2>/dev/null | head -100) || true
        else
            pci_out=$(lspci 2>/dev/null) || true
        fi
        print_result "$pci_out"
    fi

    if [[ "$VERBOSE" == true ]] && check_command lshw; then
        print_section "Memory Details (lshw)"
        local lshw_mem
        lshw_mem=$(sudo lshw -class memory 2>/dev/null) || true
        print_result "$lshw_mem"
    fi

    if [[ "$VERBOSE" == true ]] && check_command cpuid; then
        print_section "CPU Capabilities (cpuid)"
        local cpuid_out
        cpuid_out=$(cpuid 2>/dev/null | head -50) || true
        print_result "$cpuid_out"
    fi
}

# ============================================================================
# CHECK: Storage Firmware
# ============================================================================
check_storage() {
    print_header "STORAGE DEVICE FIRMWARE"

    if ! check_command smartctl; then
        print_status "smartctl" "Not installed (smartmontools package)" "error"
        return
    fi

    print_section "Storage Devices"

    # Find all block devices
    for dev in /dev/nvme[0-9]* /dev/sd[a-z]; do
        if [[ -b "$dev" ]]; then
            local dev_name
            dev_name=$(basename "$dev")

            # Skip partitions
            [[ "$dev_name" =~ [0-9]$ ]] && [[ "$dev_name" =~ ^sd ]] && continue
            [[ "$dev_name" =~ p[0-9]+$ ]] && continue

            echo ""
            echo -e "  ${BOLD}$dev${NC}"

            local smart_out
            smart_out=$(sudo smartctl -i "$dev" 2>/dev/null) || true

            if [[ -n "$smart_out" ]]; then
                local model firmware serial
                model=$(echo "$smart_out" | grep -E "Model|Device Model" | head -1 | cut -d: -f2 | xargs)
                firmware=$(echo "$smart_out" | grep -i "firmware" | head -1 | cut -d: -f2 | xargs)
                serial=$(echo "$smart_out" | grep -i "serial" | head -1 | cut -d: -f2 | xargs)

                [[ -n "$model" ]] && print_status "Model" "$model"
                [[ -n "$firmware" ]] && print_status "Firmware" "$firmware"
                [[ -n "$serial" ]] && print_status "Serial" "$serial"

                if [[ "$VERBOSE" == true ]]; then
                    local health
                    health=$(sudo smartctl -H "$dev" 2>/dev/null | grep -i "health\|result" | head -1)
                    [[ -n "$health" ]] && echo "    $health"
                fi
            else
                echo -e "    ${DIM}Could not query device${NC}"
            fi
        fi
    done
}

# ============================================================================
# RUN ALL CHECKS
# ============================================================================
run_all_checks() {
    check_secureboot
    check_bios
    check_microcode
    check_tpm
    check_fwupd
    check_intel_me
    check_firmware
    check_packages
    check_hardware
    check_storage

    print_header "SCAN COMPLETE"
    echo ""
    log "Supply chain validation completed at $(date)"
}

# ============================================================================
# MAIN
# ============================================================================

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--all)
            RUN_ALL=true
            shift
            ;;
        -l|--list)
            list_checks
            exit 0
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -q|--quiet)
            QUIET=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            # Assume it's a check category
            if [[ -n "${CHECK_CATEGORIES[$1]}" ]]; then
                SELECTED_CHECKS+=("$1")
            else
                echo "Unknown check category: $1" >&2
                echo "Use --list to see available categories" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# Print banner
echo -e "${BOLD}${BLUE}"
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         LINUX SUPPLY CHAIN VALIDATION SCANNER                     ║"
echo "║         Based on Eclypsium Security Cheat Sheet                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

if ! check_root; then
    echo -e "${YELLOW}Note: Running without root privileges. Some checks may be limited.${NC}"
    echo -e "${YELLOW}Consider running with: sudo $(basename "$0") $*${NC}"
    echo ""
fi

# Run checks
if [[ "$RUN_ALL" == true ]]; then
    run_all_checks
elif [[ ${#SELECTED_CHECKS[@]} -gt 0 ]]; then
    for check in "${SELECTED_CHECKS[@]}"; do
        case "$check" in
            secureboot) check_secureboot ;;
            bios)       check_bios ;;
            firmware)   check_firmware ;;
            fwupd)      check_fwupd ;;
            intel-me)   check_intel_me ;;
            microcode)  check_microcode ;;
            tpm)        check_tpm ;;
            packages)   check_packages ;;
            hardware)   check_hardware ;;
            storage)    check_storage ;;
        esac
    done
else
    echo "No checks specified. Use --all to run all checks or specify categories."
    echo ""
    list_checks
    echo "Example: $(basename "$0") secureboot bios microcode"
    exit 0
fi
