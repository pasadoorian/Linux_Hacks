# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a collection of standalone bash scripts for Manjaro Linux system administration, maintenance, and security auditing. Designed for personal use on Manjaro/Arch-based systems.

## Scripts

- **update.sh** - System update and maintenance: cache cleaning, mirror refresh, package updates (pamac/pacman), rebuild checks (including Python version upgrades), pacnew file listing, firmware updates, and kernel management. Auto-elevates to root. Runs all actions by default when called with no arguments; kernel management (`-k`) is intentionally excluded from `--all`.
- **supply_chain_check.sh** - Security validation scanner based on Eclypsium's cheat sheet: checks Secure Boot, BIOS/UEFI, firmware (chipsec), fwupd, Intel ME, CPU microcode/vulnerabilities, TPM, package integrity, hardware inventory, and storage firmware. Supports selective checks by category (`./supply_chain_check.sh secureboot bios`) and verbose mode.
- **mediabackup.sh** - Rsync-based backup: syncs `~/media` to NAS (`~/terramaster`) and external drive (`~/WD20TB`). Supports dry-run, delete mode, and single-destination sync.
- **reset_audio.sh** - Audio troubleshooting: auto-detects PulseAudio vs PipeWire, rescans USB, reloads ALSA, clears audio config, and restarts services. Has status-only mode (`-s`).
- **bambu.sh** - Launcher for Bambu Studio 3D printing software with Mesa/EGL environment workarounds.
- **kvm-qemu-libvirt.md** - Tutorial for KVM/QEMU/libvirt setup: server installation (Ubuntu), bridge networking, permissions, client config (Manjaro), VM creation (cloud images and pre-built images), and VM management.

## System Context

- Target system: Manjaro Linux (Arch-based)
- Package managers: pacman, pamac (with AUR support)
- Audio stack: PulseAudio or PipeWire (auto-detected)
- Key tools used: checkrebuild, pacdiff, fwupdmgr, rsync, pactl, aplay, mokutil, dmidecode, smartctl, inxi

## Conventions

- All scripts use `set -e` (update.sh uses `set -euo pipefail`)
- All scripts have `usage()` functions and support `-h/--help`
- Argument parsing uses `while [[ $# -gt 0 ]]; do case` pattern with both short and long flags
- Color output uses ANSI escape codes (defined as variables like `RED`, `GREEN`, etc.)
- Scripts that need root either auto-elevate (`exec sudo "$0" "$@"` in update.sh) or warn the user (supply_chain_check.sh)
- All scripts are executable and run directly: `./script.sh [options]` or `sudo ./script.sh [options]`
