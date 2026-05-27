# Linux Hacks

Bash scripts and guides for Manjaro Linux system administration, maintenance, and security auditing. Designed for personal use on Manjaro/Arch-based systems.

## Scripts

| Script | Description |
|--------|-------------|
| [`update.sh`](update.sh) | System update and maintenance: cache cleaning, mirror refresh, package updates (pamac/pacman), rebuild checks, pacnew file listing, firmware updates, and kernel management. Auto-elevates to root. |
| [`supply_chain_check.sh`](supply_chain_check.sh) | Security validation scanner based on [Eclypsium's cheat sheet](https://eclypsium.com/): checks Secure Boot (including [Microsoft 2026 certificate expiration](https://eclypsium.com/blog/microsoft-secure-boot-certificates-expire-2026/)), BIOS/UEFI, firmware, fwupd, Intel ME, CPU microcode/vulnerabilities, TPM, package integrity, hardware inventory, and storage firmware. Supports remote execution over SSH (`remote <host>`), with optional `--sudo` for elevated checks on the target. Banner shows the host/OS/kernel of the system being scanned. |
| [`mediabackup.sh`](mediabackup.sh) | Rsync-based backup: syncs `~/media` to NAS and external drive. Supports dry-run, delete mode, and single-destination sync. |
| [`reset_audio.sh`](reset_audio.sh) | Audio troubleshooting: auto-detects PulseAudio vs PipeWire, rescans USB, reloads ALSA, clears audio config, and restarts services. |
| [`bambu.sh`](bambu.sh) | Launcher for Bambu Studio 3D printing software with Mesa/EGL environment workarounds. |

## Guides

| Guide | Description |
|-------|-------------|
| [`kvm-qemu-libvirt.md`](kvm-qemu-libvirt.md) | Step-by-step tutorial for KVM/QEMU/libvirt setup with a Manjaro client managing VMs on a remote Ubuntu server. Covers installation, bridge networking, permissions, and VM creation workflows. |

## Usage

All scripts are standalone and can be run directly:

```bash
./update.sh                                    # Run all update tasks
./update.sh -k                                 # Kernel management only
./supply_chain_check.sh --all                  # Full local security scan
./supply_chain_check.sh secureboot             # Single check (also includes 2026 cert expiry)
./supply_chain_check.sh remote --sudo host all # Scan a remote host over SSH
./mediabackup.sh -d                            # Dry-run backup
./reset_audio.sh -s                            # Audio status check
```

Every script supports `-h` / `--help` for usage details.

## System Requirements

- Manjaro Linux (or Arch-based)
- Package managers: `pacman`, `pamac` (with AUR support)
- Root access for most operations (scripts auto-elevate or warn as needed)

## Author

Paul Asadoorian
