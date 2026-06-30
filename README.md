# Linux Hacks

Bash scripts and guides for Manjaro Linux system administration, maintenance, and security auditing. Designed for personal use on Manjaro/Arch-based systems.

## Scripts

| Script | Description |
|--------|-------------|
| [`update.sh`](update.sh) | System update & maintenance: cache cleaning, mirror refresh, package updates split into two configurable tools — **`SYSTEM_UPDATER`** for repos (pacman, default; or pamac) and **`AUR_UPDATER`** for the AUR (yay, default — with PKGBUILD review + supply-chain hooks; or pamac; or none), foreign-package review + orphan removal (`-o`), rebuild checks for **library/ABI** (`-r`) and **Python-version** (`-y`) breakage (rebuilt via `AUR_UPDATER`), pacnew listing, firmware, and kernel management. Adds an **AUR supply-chain layer**: `-A` audit (RPC metrics + maintainer re-adoption detection) and `-S` scan (live malware IOC lists + host-persistence checks). Config-file driven, clean sectioned output. Auto-elevates to root. See [`UPDATE_README.md`](UPDATE_README.md). |
| [`aur-precheck.sh`](aur-precheck.sh) | Per-package AUR supply-chain pre-flight (orphaned / out-of-date / stale / compromised name / malicious maintainer). Used by the yay hook at install time, and usable standalone. |
| [`yay-init.lua`](yay-init.lua) | Advisory yay v13 hooks (deployed to `~/.config/yay/init.lua`): an `AURPreInstall` PKGBUILD build-logic scan + `aur-precheck.sh` call, and an `UpgradeSelect` maintainer-change warning. Warns loudly, never blocks. |
| [`supply_chain_check.sh`](supply_chain_check.sh) | Security validation scanner based on [Eclypsium's cheat sheet](https://eclypsium.com/): Secure Boot (incl. [Microsoft 2026 cert expiration](https://eclypsium.com/blog/microsoft-secure-boot-certificates-expire-2026/)), BIOS/UEFI, firmware, fwupd, Intel ME, CPU microcode/vulnerabilities, TPM, package integrity, hardware inventory, storage firmware. Supports remote execution over SSH (`remote <host>`), optional `--sudo`. |
| [`mediabackup.sh`](mediabackup.sh) | Rsync-based backup: syncs `~/media` to NAS and external drive. Dry-run, delete mode, single-destination sync. |
| [`reset_audio.sh`](reset_audio.sh) | Audio troubleshooting: auto-detects PulseAudio vs PipeWire, rescans USB, reloads ALSA, clears config, restarts services. |
| [`bambu.sh`](bambu.sh) | Launcher for Bambu Studio with Mesa/EGL environment workarounds. |

Shared code lives in [`lib/`](lib/): `aur-common.sh` (AUR RPC + IOC helpers, used by `update.sh` and `aur-precheck.sh`) and `output.sh` (terminal output helpers — color/TTY/`NO_COLOR` aware sections, status lines, and run summaries).

## Guides

| Guide | Description |
|-------|-------------|
| [`kvm-qemu-libvirt.md`](kvm-qemu-libvirt.md) | KVM/QEMU/libvirt setup: a Manjaro client managing VMs on a remote Ubuntu server — installation, bridge networking, permissions, VM creation. |
| [`docs/aur-precheck-plan.md`](docs/aur-precheck-plan.md) | Design/decision record for the install-time AUR supply-chain checks. |

## Usage

All scripts are standalone and run directly:

```bash
./update.sh                       # Run the default maintenance actions (yay for AUR)
./update.sh -A -S                 # Audit + scan AUR packages (recommended before AUR upgrades)
./update.sh -u -P                 # Update official repos only (pacman, no AUR)
./update.sh -k                    # Kernel management only
./update.sh --print-config        # Show effective configuration
./update.sh -q                    # Quiet output (warnings/errors only)
./aur-precheck.sh some-aur-pkg    # Pre-flight a single AUR package
./supply_chain_check.sh --all     # Full local security scan
./supply_chain_check.sh remote --sudo host all   # Scan a remote host over SSH
./mediabackup.sh -d               # Dry-run backup
./reset_audio.sh -s               # Audio status check
```

Every script supports `-h` / `--help`.

## Configuration

`update.sh` reads an optional config file at `~/.config/update.sh/config`
(auto-created from [`update.conf.example`](update.conf.example) on first run).
It controls default actions, the AUR backend, exclusion lists (`EXCLUDE_ALIEN`,
`KEEP_ORPHANS`, `LUA_ALLOWLIST`), and the install-time check tunables
(`AUR_PRECHECK*`). Precedence: built-in defaults < config file < CLI flags.
See the [configuration section](UPDATE_README.md#configuration) of `UPDATE_README.md`.

## Tests

`update.sh` and `yay-init.lua` have a test suite (bats + a small Lua harness):

```bash
./tests/run-tests.sh        # bash -n, luac, shellcheck (if present), bats + lua
```

See [`tests/README.md`](tests/README.md). bats is vendored as git submodules, so
after a fresh clone run `git submodule update --init --recursive` (the runner
does this automatically).

## System Requirements

- Manjaro Linux (or Arch-based)
- Package managers: `pacman`, `pamac`; `yay` v13+ for the default AUR flow and the install-time hooks
- `jq` and `curl` for the AUR audit/scan/precheck
- Root access for most operations (scripts auto-elevate or warn as needed)

## Author

Paul Asadoorian
