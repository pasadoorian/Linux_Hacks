# `update.sh` — Manjaro System Update & AUR Supply-Chain Audit

A single, root-elevating maintenance script for Manjaro Linux. It handles the
routine work (cache cleanup, orphan removal, system updates, rebuild checks,
pacnew/firmware/kernel management) **and** adds a dedicated AUR security layer
for auditing package health and scanning for supply-chain malware in the wake of
the June 2026 **"Atomic Arch"** AUR compromise.

- **Path:** `~/update.sh`
- **Run as:** any user — the script re-executes itself with `sudo` automatically.
  AUR/build operations are dropped back to your real user (`$SUDO_USER`) because
  makepkg/yay must never run as root.

---

## Table of contents

1. [Quick start](#quick-start)
2. [Requirements](#requirements)
3. [All options](#all-options)
4. [Concepts (foreign vs. orphaned, rebuild vs. python rebuild)](#concepts)
5. [Modifiers](#modifiers)
6. [The yay updater (default) and why it beats pamac for AUR](#the-yay-updater-default-and-why-it-beats-pamac-for-aur)
7. [AUR audit (`-A`) — reading the metrics table](#aur-audit--a--reading-the-metrics-table)
   - [Column-by-column](#column-by-column)
   - [FLAGS reference](#flags-reference)
   - [Special report lines](#special-report-lines)
   - [Maintainer-change / re-adoption detection](#maintainer-change--re-adoption-detection)
8. [AUR scan (`-S`) — malware IOC checks](#aur-scan--s--malware-ioc-checks)
9. [Install-time warnings (the yay hooks)](#install-time-warnings-the-yay-hooks)
10. [Background: the Atomic Arch attack](#background-the-atomic-arch-attack)
11. [Recommended workflows](#recommended-workflows)
12. [Configuration](#configuration)
13. [Safety notes & caveats](#safety-notes--caveats)

---

## Quick start

```bash
sudo ~/update.sh             # run everything; AUR updated via yay (with review)
sudo ~/update.sh -A -S       # audit + scan your AUR packages (read-only, explicit)
sudo ~/update.sh -u          # update only: pacman for repos, yay for AUR (default)
sudo ~/update.sh -h          # full help
```

**Defaults:** a normal run updates AUR packages with **yay** (repos via pacman,
AUR via yay with diff review). The **security checks (`-A`, `-S`) are
explicit-only** — they never run as part of a normal/`--all` run; you ask for
them by name.

**Golden rule before any AUR upgrade:** run `-A -S` first, read the flags, *then*
upgrade. The audit/scan are read-only and never build anything.

---

## Requirements

| Tool | Used for | Install |
|------|----------|---------|
| `pacman`, `pamac` | base package management | (stock Manjaro) |
| `yay` (v13+) | **default** AUR update backend; PKGBUILD timestamps & Lua hooks | `pamac build yay` |
| `curl` | AUR RPC queries + fetching live IOC lists | `pacman -S curl` |
| `jq` | parsing AUR RPC JSON & IOC data | `pacman -S jq` |
| `checkrebuild` (pacman-contrib / rebuild-detector) | `-r` rebuild detection | `pacman -S rebuild-detector` |
| `fwupd` | `-f` firmware | `pacman -S fwupd` |
| `mhwd-kernel` | `-k` kernel mgmt | (stock Manjaro) |

The `-A` audit and `-S` scan require **`curl` + `jq`** and an internet connection
(they query the AUR RPC and fetch the latest malicious-package lists live).

---

## All options

Actions are additive — pass as many as you like. With **no action flags**, the
script runs the configured **`DEFAULT_ACTIONS`** set (the built-in default
matches the old `--all` behavior — see [Configuration](#configuration)).

| Flag | Long form | Action |
|------|-----------|--------|
| `-c` | `--clean` | Clean pacman/pamac/yay/paru caches and stale db locks |
| `-o` | `--orphans` | Inventory **foreign** (AUR/manual) packages to `~/alien-pkgs.txt` for review, then prompt to remove **orphaned** deps. Two different concepts — see [Foreign vs. orphaned](#foreign-vs-orphaned-packages) |
| `-u` | `--update` | Full system update (**yay by default**: pacman repos + yay AUR; see modifiers) |
| `-r` | `--rebuilds` | Find packages broken by a **library/ABI change** (`checkrebuild`); rebuild with `-R` (via the configured `AUR_UPDATER` — yay by default). See [Rebuild vs. Python rebuild](#rebuild-r-vs-python-rebuild-y) |
| `-y` | `--python-rebuild` | Find packages stranded by a **Python interpreter version bump**; rebuild with `-R` (via `AUR_UPDATER`). See [Rebuild vs. Python rebuild](#rebuild-r-vs-python-rebuild-y) |
| `-p` | `--pacnew` | Show `.pacnew` files needing a merge (`pacdiff -o`) |
| `-f` | `--firmware` | Refresh & list firmware updates (`fwupdmgr`) |
| `-k` | `--kernel` | Interactive kernel install/remove (`mhwd-kernel`) |
| **`-A`** | **`--aur-audit`** | **(explicit-only)** Per-AUR-package metrics + maintainer-change detection |
| **`-S`** | **`--aur-scan`** | **(explicit-only)** Scan installed AUR packages against live malware IOCs |
| `-a` | `--all` | Run all actions **except** `-k`, `-A`, and `-S` |
| `-h` | `--help` | Show usage |

### What `--all` includes and excludes

`--all` (the default when you pass no arguments) runs: clean, orphans, update
(**AUR via yay, with diff review**), rebuilds, python-rebuild, pacnew, and
firmware.

It deliberately **excludes**:

- **`-k` kernel management** — needs interactive decisions.
- **`-A` aur-audit and `-S` aur-scan** — the security checks are **explicit-only**.
  A routine update shouldn't be gated on network IOC fetches or audit output, so
  you request them by name (`-A` / `-S`) when you want them. They are read-only
  and never build anything.

> **Note on the default update:** because the default `AUR_UPDATER` is yay,
> a normal `--all` (or `-u`) run *does* upgrade AUR packages — but always through
> yay's diff/edit review menus, so you see and approve every PKGBUILD change
> before it builds. Use `--aur-updater none` for a fully non-interactive,
> repos-only update.

---

## Concepts

`-o` and the two rebuild checks each bundle a pair of ideas that are easy to
confuse. This section explains them once.

### Foreign vs. orphaned packages

These are **orthogonal** — `-o` happens to do both, which is why they get mixed up:

| | Foreign | Orphaned |
|---|---------|----------|
| **Question** | *Where did it come from?* | *Why is it still here?* |
| **Definition** | Installed but **not in any sync database** (`pacman -Qm`) | Installed **as a dependency** that **nothing requires anymore** (`pacman -Qtdq`) |
| **In practice** | Your **AUR builds** and manual `pacman -U` installs | Leftover dependency cruft after something was removed |
| **What `-o` does** | **Lists** them to `~/alien-pkgs.txt` (never auto-removed) | **Offers to remove** them (skipping `KEEP_ORPHANS`, prompting per item) |

A package can be either, both, or neither: a repo library installed as a dep and
now unneeded is **orphaned but not foreign**; an AUR app you chose to install is
**foreign but not orphaned**.

**What review does the foreign list need?** `~/alien-pkgs.txt` is your *inventory*
of packages that get **no official-repo updates** and carry AUR supply-chain
risk. For each entry decide:

1. **Do I still use it?** Remove what you don't: `yay -Rns <pkg>` (or `pacman -Rns`).
2. **Is it still safe/healthy?** That's exactly what `-A` and `-S` automate —
   `-A` flags orphaned-in-AUR / out-of-date / maintainer changes, `-S` checks the
   live compromised-package lists. So: `alien-pkgs.txt` is the inventory, **`-A`/`-S`
   are the vetting.** Excluded entries (vetted-and-trusted) go in `EXCLUDE_ALIEN`.

### Rebuild (`-r`) vs. Python rebuild (`-y`)

Both find packages that need rebuilding, but for **different kinds of breakage**:

| | `-r` rebuild check | `-y` Python rebuild check |
|---|--------------------|---------------------------|
| **Trigger** | A shared library's **soname/ABI changed** (e.g. `libfoo.so.1` → `.so.2`) | The **Python interpreter** bumped (e.g. 3.11 → 3.13) |
| **How** | `checkrebuild` (rebuild-detector): finds packages **linking a `.so` that changed or vanished** | Finds packages **owning files under a stale `/usr/lib/python3.OLD/`** dir (`pacman -Qoq`) |
| **Catches** | Any native/compiled package with a broken library link | Packages stranded in the old Python dir |

Why both? They **overlap but neither subsumes the other.** Compiled Python
extensions (linking `libpython3.X.so`) appear in *both*. But **pure-Python**
packages just drop `.py` files into the versioned dir — no broken `.so`, so
`checkrebuild` misses them; `-y` catches those by directory ownership.

Both honor `-R`/`--auto-rebuild` to actually rebuild — **through the configured
`AUR_UPDATER`** (see [Modifiers](#modifiers)): with the default `yay` a rebuild is
`yay -S --rebuild` with the diff/edit review menus, so it goes through the same
PKGBUILD review and the [install-time supply-chain hooks](#install-time-warnings-the-yay-hooks)
as a normal install, and uses yay's resumable build cache. `AUR_UPDATER=pamac`
uses `pamac build`; `AUR_UPDATER=none` **refuses** (no AUR helper) — set
`--aur-updater yay` (or `pamac`) to rebuild.

---

## Modifiers

These change *how* an action behaves; they do nothing on their own.

`-u` runs **two independent steps**, each with its own tool, so it's always clear
which tool does what. Set them in the [config](#configuration) (`SYSTEM_UPDATER` /
`AUR_UPDATER`) or override per-run:

| Flag | Value(s) | Effect |
|------|----------|--------|
| `--system-updater` | `pacman` *(default)* · `pamac` | Tool for the **official repos** |
| `--aur-updater` | `yay` *(default)* · `pamac` · `none` | Tool for the **AUR**. `yay` = with PKGBUILD review + supply-chain hooks; `pamac` = pamac (also manages repos — see below); `none` = skip AUR |
| `-R` | `--auto-rebuild` | `-r` / `-y` actually rebuild (y/n confirm) instead of just listing — via the `AUR_UPDATER` (yay `--rebuild` with review by default; `none` refuses) |

| `SYSTEM_UPDATER` | `AUR_UPDATER` | Result |
|---|---|---|
| `pacman` | `yay` | **default** — `pacman -Syuu`, then `yay -Sua` (review + hooks) |
| `pacman` | `none` | repos only (`pacman -Syuu`), AUR skipped |
| `pamac` | `yay` | `pamac update` for repos, then `yay -Sua` for AUR |
| *(any)* | `pamac` | `pamac update -a` does **both** — pamac is all-in-one, so it manages repos too regardless of `SYSTEM_UPDATER` |

> The old `-Y` / `-P` / `-m` flags and the single `UPDATER=` config key are **gone**
> (replaced by the two settings above). A legacy `UPDATER=` in your config is still
> honored for now, mapped with a deprecation warning.

### Configuration flags

These control the config file (see [Configuration](#configuration)); they are
not actions, so on their own the `DEFAULT_ACTIONS` set still runs.

| Flag | Effect |
|------|--------|
| `--config FILE` | Use `FILE` instead of `~/.config/update.sh/config` |
| `--no-config` | Ignore the config file entirely; use built-in defaults |
| `--print-config` | Print the **effective** settings (defaults + config + CLI) and exit |

### Output flags

The script prints clean, sectioned output: each action gets a `▸ [n/total]
Title` header, status lines (`✓`/`!`/`✗`), and a final **Summary** with
suggested next steps. Noisy sub-commands (cache/mirror/firmware) are collapsed to
a one-line status by default. Color is automatic on an interactive terminal and
off when piped, when `NO_COLOR` is set, or with `--no-color`.

| Flag | Effect |
|------|--------|
| `-v`, `--verbose` | Show full output from the cache/mirror/firmware sub-commands |
| `-q`, `--quiet` | Only warnings and errors (suppress headers, status, summary) |
| `--no-color` | Disable colored output (also honored: `NO_COLOR`, `TERM=dumb`) |

---

## The yay updater (default) and why it beats pamac for AUR

```bash
sudo ~/update.sh -u                       # defaults: repos via pacman, AUR via yay
sudo ~/update.sh -u --aur-updater none    # repos only, skip AUR
```

By default `-u` refreshes mirrors, updates official repos with `pacman -Syuu`, then
updates AUR packages with **yay** (`yay -Sua`) running as your real user. yay is
invoked with the diff/edit menus enabled so **you review every PKGBUILD and every
diff before anything builds** — and it triggers the
[install-time supply-chain hooks](#install-time-warnings-the-yay-hooks).

**Benefits over pamac's `-a` AUR handling:**

| Capability | pamac | yay v13 |
|------------|:-----:|:-------:|
| Shows **PKGBUILD last-modified timestamp** in the upgrade menu | ✗ | ✓ |
| Forced **diff review** of what changed since your last build | limited | ✓ (`--diffmenu`) |
| **Edit PKGBUILD** before build | ✗ | ✓ (`--editmenu`) |
| **Lua hooks** (`~/.config/yay/init.lua`) for automated pre-install vetting | ✗ | ✓ |
| `-git`/`-devel` source freshness checks (`--devel`) | partial | ✓ |
| Combined repo+AUR transaction (`--combinedupgrade`) | ✗ | ✓ |

The last-modified timestamp is the headline feature: a package whose PKGBUILD
changed *yesterday* after years of silence is exactly the profile of an adopted-
then-poisoned package. yay surfaces that right in the upgrade prompt so you can
stop and look before committing.

> **Optional hardening:** create `~/.config/yay/init.lua` with an
> `AURPostDownload` hook that aborts when a freshly downloaded PKGBUILD contains
> `npm install` / `bun` / `curl | sh` patterns. That protection then runs on
> *every* future `yay` invocation, not just through this script.

---

## AUR audit (`-A`) — reading the metrics table

```bash
sudo ~/update.sh -A
```

The audit queries the **AUR RPC v5 `info` endpoint** for all your installed
foreign packages (`pacman -Qmq`) in one batched call, then prints a table and
saves the full report to **`~/aur-audit.txt`**.

Example row:

```
PACKAGE                            MAINTAINER        AGE(d) OOD       VOTES  FLAGS
------------------------------------------------------------------------------------------
adwaita-color-schemes              q234rty              715 FLAGGED       2  OUT-OF-DATE
brave-bin                          brave                  2 -          1017  RECENTLY-CHANGED
audacity-plugins                   defaultxr            945 -             3
gnome-shell-extension-x11gestures  ORPHAN                17 -             5  ORPHAN RECENTLY-CHANGED
```

### Column-by-column

- **PACKAGE** — the installed AUR package name.

- **MAINTAINER** — the package's *current* AUR maintainer account, or **`ORPHAN`**
  if it has none. This is pulled live from the AUR, so it reflects the present
  state, not who built your installed copy.
  - **Why it matters:** orphaned packages are the primary target of supply-chain
    attacks. Attackers *adopt* an orphan to inherit its established user base,
    then poison the PKGBUILD. A maintainer you don't recognize on a package that
    was orphaned last week deserves scrutiny.

- **AGE(d)** — **days since the PKGBUILD was last modified** on the AUR
  (`now − LastModified`, in whole days). This is about the *recipe*, not your
  install date.
  - **Low number (e.g. 0–21):** recently changed. Earns the `RECENTLY-CHANGED`
    flag. **Not inherently bad** — popular packages update often — but it's the
    single most useful "look closer" signal, because a poisoned PKGBUILD is, by
    definition, recently modified. Cross-check *who* changed it and *why*.
  - **High number (e.g. 700+):** the recipe has been untouched for a long time.
    Usually fine (stable software), but a very stale package that's also
    `ORPHAN` or `OUT-OF-DATE` may be abandoned and a future adoption target.
  - **Interpretation is contextual:** recency alone is neither safe nor unsafe.
    Combine AGE with maintainer changes and votes.

- **OOD** — the AUR **"Out of Date"** flag. This column is derived purely from
  the AUR RPC's `OutOfDate` field:

  ```bash
  (if .OutOfDate == null then "-" else "FLAGGED" end)
  ```

  - **`-`** → `OutOfDate` is `null`, i.e. nobody has flagged it.
  - **`FLAGGED`** → `OutOfDate` is a Unix timestamp, set the moment a registered
    AUR user clicked the **"Flag package out-of-date"** button on that package's
    AUR page. It stays set until the **maintainer** pushes an update and clears
    it. (The script collapses the timestamp to the word `FLAGGED`; the exact date
    is visible via the RPC / in your notes.)

  **What it does and doesn't mean:**
  - It is a label on the **remote AUR record**, not a property of your installed
    files — nothing local triggers it.
  - It does **not** mean an update is available to install; it means upstream is
    ahead of what the maintainer has packaged.
  - It is **not** a security indicator by itself.

  **Triage — `FLAGGED` covers two very different situations**, and the
  `MAINTAINER` / `AGE(d)` / `VOTES` columns are how you tell them apart:

  | Pattern | Reading | Action |
  |---------|---------|--------|
  | `FLAGGED`, low AGE, active/known maintainer | A **healthy** project just moved ahead of the package; the maintainer will likely catch up | **Keep** — it's a non-problem |
  | `FLAGGED`, high AGE (100s of days), few votes, `ORPHAN` or dead upstream | The project is **abandoned**; the flag will never clear | **Remove** or migrate to a successor |

  > Worked example: `mailspring` (51 days, active maintainer) → *keep*, just
  > briefly behind. `qgnomeplatform-qt5/qt6` (715 days, 2 votes, deprecated
  > upstream) → *remove* — those flags will never clear because the project is
  > dead. Same `FLAGGED` string, opposite conclusions.

- **VOTES** — the number of AUR user votes (popularity/trust proxy).
  - **High (hundreds–thousands):** widely used; problems tend to surface fast on
    the AUR comments/mailing list. A measure of community eyes, not a guarantee.
  - **Low (single digits):** niche package, fewer people watching it. Combined
    with a recent maintainer change, low votes mean *you* are more likely to be
    among the first to notice (or be hit by) a malicious change. Treat low-vote +
    recently-adopted packages with extra caution.

- **FLAGS** — zero or more space-separated tags (see next section).

### FLAGS reference

| Flag | Meaning | How to interpret |
|------|---------|------------------|
| `ORPHAN` | Package currently has **no maintainer** on the AUR | Higher supply-chain risk — orphans are adoption targets. Fine to keep using, but watch for it suddenly gaining a maintainer (see re-adoption detection). |
| `OUT-OF-DATE` | Package is **flagged out-of-date** on the AUR | Maintenance/freshness signal, **not** security. Upstream moved on; PKGBUILD hasn't. Chronic + orphaned = likely abandoned. |
| `RECENTLY-CHANGED` | PKGBUILD modified within **`AUR_RECENT_DAYS` (default 21)** days | The key "eyeball this" cue. Normal for active packages; suspicious when paired with a new/unknown maintainer or a recent orphan→adopted transition. |

> Flags are **signals, not verdicts.** A single flag is rarely alarming. The
> dangerous pattern is a *combination*: e.g. `ORPHAN RECENTLY-CHANGED` on a
> low-vote package, or a `RECENTLY-CHANGED` package whose maintainer just changed.

### Special report lines

Beyond the table, the audit may print:

- **`NOT FOUND IN AUR (deleted/renamed - investigate): <pkgs>`**
  You have a foreign package installed that no longer resolves on the AUR. It was
  deleted (possibly *because* it was malicious and removed by the Arch team),
  renamed, or moved to the official repos. Investigate each one.

- **`=== Maintainer changes since last run ===`** — see below.

- **`!!! MAINTAINED BY A KNOWN-MALICIOUS ACCOUNT - REMOVE/INVESTIGATE NOW:`**
  One of your packages is currently maintained by an account on the community
  blocklist of confirmed-malicious AUR accounts. **Highest priority** — treat as
  compromised until proven otherwise.

### Maintainer-change / re-adoption detection

This is the centerpiece defense against the Atomic Arch attack pattern.

On each run the audit snapshots **every package's maintainer** to
`~/.cache/update-aur/maintainers.json`, then **diffs against the previous run**.
Any change prints:

```
=== Maintainer changes since last run ===
  [REVIEW BEFORE UPGRADE] some-pkg: ORPHAN  ->  newmaintainer
  [REVIEW BEFORE UPGRADE] other-pkg: oldmaintainer  ->  differentperson
```

- **`ORPHAN -> someone`** — an orphaned package was just **adopted**. This is the
  exact move attackers used in Atomic Arch. Verify the new maintainer and inspect
  the PKGBUILD diff before you ever rebuild it.
- **`maintainerA -> maintainerB`** — the package changed hands. Could be a
  legitimate handover or a hostile takeover. Review before upgrading.
- **`someone -> ORPHAN`** — the maintainer left (or was **banned**, e.g. after a
  malicious commit was reverted). Worth knowing.

The **first run** establishes a baseline and reports "none" — detection improves
on every subsequent run as history accumulates. The snapshot is owned by your
real user, not root.

> **Why this matters more than a static blocklist:** blocklists only catch *known*
> bad accounts after disclosure. The maintainer-change diff catches the
> *behavior* (an orphan being adopted, a package changing hands) **before** any
> public attribution exists — giving you a chance to review the PKGBUILD yourself.

---

## AUR scan (`-S`) — malware IOC checks

```bash
sudo ~/update.sh -S
```

The scan fetches the **latest** indicator lists from the community
[`lenucksi/aur-malware-check`](https://github.com/lenucksi/aur-malware-check)
repository on every run (covering the `aur-infected`, `chaos-rat`, and
`russian-spam` campaigns) and checks your system against them. It performs four
groups of checks and prints a count of flagged indicator groups at the end.

1. **Installed packages vs. known-malicious lists**
   Compares `pacman -Qmq` against ~2,000 known-compromised AUR package names.
   - `!!! COMPROMISED PACKAGE INSTALLED: <pkg>` — that package was part of a
     campaign. (Note: being *listed* means the PKGBUILD was poisoned upstream; it
     does **not** automatically mean *your* build is infected — see "Were you
     actually hit?" below.)
   - If the lists can't be fetched (offline), the scan **warns loudly** and falls
     back to a tiny built-in seed list, so a failed download never reads as
     "all clear."

2. **JS package caches for injected dependencies**
   Searches `~/.npm`, `~/.bun`, `~/.cache/yarn`, pnpm stores, etc. for the
   malicious npm/bun packages the attack pulled in
   (`atomic-lockfile`, `js-digest`, `lockfile-js`, `nextfile-js`).
   - `!!! MALICIOUS JS PACKAGE TRACE: '<name>' under <dir>` — strong evidence a
     poisoned build actually ran on your machine.

3. **Risky build logic in cached PKGBUILDs / install hooks**
   Greps yay/paru/pamac build caches for `npm|bun|pnpm|yarn install/add`,
   `curl … | sh`, and `wget … | sh` patterns in `PKGBUILD`, `*.install`, `*.sh`.
   - Prints the files to review. A flag here means a cached recipe contains
     network-fetch or JS-install logic worth eyeballing.

4. **Host persistence / rootkit indicators** (the Atomic Arch payload)
   - `/sys/fs/bpf/hidden_*` — the eBPF rootkit's hidden maps.
   - `~/.local/bin/sudo` — a trojaned `sudo` shim that grabs your password.
   - systemd units with **`Restart=always` + `RestartSec=30`** — the payload's
     persistence signature.

**Result line:**
- `Scan complete: no indicators matched.` — clean against *known* campaigns. Not
  an absolute guarantee (lists only cover disclosed attacks).
- `Scan complete: N indicator group(s) flagged above - INVESTIGATE.` — review each
  `!!!` / review line printed above.

### Were you actually hit? (interpreting a "COMPROMISED PACKAGE INSTALLED" hit)

These attacks execute their payload **at build/install time** (via PKGBUILD and
`.install` hooks). So a listed package only harmed you if you **built or upgraded
it during the attack window**. To check a specific package:

```bash
# When did you last (re)install/upgrade it?
grep '<pkgname>' /var/log/pacman.log*

# Does its local DB entry contain a payload-bearing install scriptlet?
ls -la /var/lib/pacman/local/<pkgname>-<ver>/
```

If your install predates the poisoning (the PKGBUILD's `Last Modified` /
`LastModified` is *after* your install date) and there's no `.INSTALL` file, your
binary was built from a clean recipe and the payload never ran — corroborate with
the group-4 host checks above.

---

## Install-time warnings (the yay hooks)

`-A`/`-S` audit packages you've **already installed**. To catch a suspicious
package **at the moment you install or upgrade it**, `yay-init.lua` registers two
advisory hooks in yay v13 (Lua 5.1). Both **warn only — they never block**; yay's
normal clean/diff/edit menus still run. `CRIT` findings print a loud banner via
`yay.log.error`; lesser ones via `yay.log.warn`.

| Hook | When it fires | What it checks | Network? |
|------|---------------|----------------|----------|
| `AURPreInstall` | every AUR install/upgrade, per package | PKGBUILD/`.install` **build-logic** scan (npm/pipe-to-sh/IOC names), then `aur-precheck.sh` → **orphaned / out-of-date / stale / compromised name / malicious maintainer** | local scan = no; precheck = one RPC + cached IOC lists |
| `UpgradeSelect` | during `yay -Syu`, before the exclude menu | **maintainer change** since last upgrade (the re-adoption tell) — uses the maintainer field yay provides | no |

**`aur-precheck.sh <pkg>`** is the bridge: it does one AUR RPC query plus a
TTL-cached IOC lookup for a single package and prints `CRIT`/`WARN` lines. It's
also usable standalone (`./aur-precheck.sh some-aur-pkg`) and shares its logic
with `update.sh` via `lib/aur-common.sh`. It honors the same `LUA_ALLOWLIST`
(via `~/.config/yay/allowlist.txt`) and degrades silently offline.

Why two hooks: `AURPreInstall` does not receive the maintainer field, so the
maintainer-change check lives in `UpgradeSelect` (which does); everything else is
per-package and lives in `AURPreInstall`. Tune behavior with `AUR_PRECHECK*` in
the [config](#configuration).

> **Deploy:** the live hook yay reads is `~/.config/yay/init.lua`. After updating
> the repo's `yay-init.lua`, copy it across: `cp yay-init.lua ~/.config/yay/init.lua`.

---

## Background: the Atomic Arch attack

On **June 11–12, 2026**, attackers compromised ~1,500 AUR packages by
**systematically adopting orphaned packages** and injecting build logic that ran
`npm install atomic-lockfile` (wave 1) and Bun-based `js-digest` / `lockfile-js`
(wave 2). The payload was a Rust infostealer (targeting OpenAI, GitHub, npm,
Discord, Slack, MS Teams credentials, exfil to a Tor C2 + `temp.sh`) plus an
eBPF rootkit and a trojaned `~/.local/bin/sudo`. The Arch team reverted the
malicious commits, banned the accounts, and the AUR suspended new registrations.

The features in this script map directly onto that attack chain:

| Attack step | Defense in this script |
|-------------|------------------------|
| Adopt an orphaned package | `-A` maintainer-change detection (`ORPHAN -> x`) + `ORPHAN` flag |
| Poison the PKGBUILD recently | `-A` `RECENTLY-CHANGED` flag + yay last-modified timestamps |
| Use a throwaway attacker account | `-A` known-malicious-account cross-reference |
| Pull a malicious npm/bun dep at build | `-S` JS-cache + build-logic scan |
| Drop rootkit / persistence / sudo shim | `-S` host IOC checks |
| Build without review | yay (default) forced diff/edit menus before building |

---

## Recommended workflows

**Routine maintenance (default — AUR via yay with review, no security scans):**
```bash
sudo ~/update.sh            # everything except kernel mgmt & the -A/-S checks
```

**Security check-up of your AUR packages (read-only, explicit):**
```bash
sudo ~/update.sh -A -S      # audit metrics + malware scan; read ~/aur-audit.txt
```

**Cautious AUR upgrade — review security first, then update:**
```bash
sudo ~/update.sh -A -S      # 1. review flags & maintainer changes first
sudo ~/update.sh -u         # 2. upgrade (yay default), reviewing each PKGBUILD diff
```

**Official-repos-only update (skip AUR entirely, non-interactive):**
```bash
sudo ~/update.sh -u -P
```

**Update via pamac instead of yay:**
```bash
sudo ~/update.sh -u -m
```

---

## Configuration

`update.sh` reads an optional config file, sourced as bash:

```
~/.config/update.sh/config
```

On the first run it is **auto-created** from [`update.conf.example`](update.conf.example)
(which documents every setting). Point at a different file with `--config FILE`,
skip it with `--no-config`, and inspect the merged result with `--print-config`.

**Precedence** (lowest → highest): built-in defaults → config file → CLI flags.
A CLI flag always wins over the config (e.g. `--aur-updater none` overrides `AUR_UPDATER="yay"`).

**Safety gate:** because the file is sourced **as root**, the script refuses to
read it if it is world-writable or not owned by you or root, falling back to
built-in defaults with a warning.

### Settings

| Setting | Type | Default | Meaning |
|---------|------|---------|---------|
| `DEFAULT_ACTIONS` | list | `clean orphans update rebuilds python-rebuild pacnew firmware` | Checks to run when no action flag is given |
| `SYSTEM_UPDATER` | `pacman`/`pamac` | `pacman` | Tool for official repos (`--system-updater`) |
| `AUR_UPDATER` | `yay`/`pamac`/`none` | `yay` | Tool for the AUR (`--aur-updater`); `yay` enables review + hooks, `none` skips AUR |
| `AUTO_REBUILD` | bool | `false` | Default for `-R` (rebuild on `-r`/`-y`) |
| `AUR_RECENT_DAYS` | int | `21` | Days within which a PKGBUILD counts as `RECENTLY-CHANGED` |
| `AUR_IOC_CAMPAIGNS` | list | `aur-infected chaos-rat russian-spam` | Threat-intel campaigns `-A`/`-S` load |
| `EXCLUDE_ALIEN` | list | *(empty)* | Foreign pkgs suppressed from `~/alien-pkgs.txt` and the `-A`/`-S` reports |
| `KEEP_ORPHANS` | list | *(empty)* | Orphans never offered for removal by `-o` |
| `LUA_ALLOWLIST` | list | `mailspring` | Pkgs allowlisted in the yay tripwire hook |
| `AUR_PRECHECK` | bool | `true` | Master switch for the network-backed [install-time checks](#install-time-warnings-the-yay-hooks) |
| `AUR_PRECHECK_MAX_AGE_DAYS` | int | `365` | Install-time staleness threshold (PKGBUILD older than this → warn) |
| `AUR_IOC_CACHE_TTL` | int | `21600` | Seconds to cache IOC lists for the install-time check (6h) |

All three list-type exclusions accept **exact names or shell globs**
(`python-*`, `*-git`). Suppression counts are printed so nothing is hidden
silently. `LUA_ALLOWLIST` is written to `~/.config/yay/allowlist.txt` (which the
`init.lua` hook reads) on every run — that config entry is the single source of
truth, so don't hand-edit `allowlist.txt`.

> A handful of internal constants (`AUR_IOC_RAW_BASE`, `AUR_SEED_BAD_NPM`,
> `AUR_STATE_DIR`) remain near the top of `update.sh` for rare manual tweaks.

### State files

| Path | Purpose |
|------|---------|
| `~/aur-audit.txt` | Full per-package audit report (overwritten each `-A` run) |
| `~/alien-pkgs.txt` | Foreign-package list saved by `-o` (minus `EXCLUDE_ALIEN`) |
| `~/.cache/update-aur/maintainers.json` | Maintainer snapshot for `-A` re-adoption detection |
| `~/.cache/update-aur/maintainer_cache` | Maintainer cache for the `UpgradeSelect` hook (install-time) |
| `~/.cache/update-aur/ioc/` | TTL-cached IOC lists used by `aur-precheck.sh` |
| `~/.config/yay/allowlist.txt` | Tripwire allowlist, synced from `LUA_ALLOWLIST` |

---

## Safety notes & caveats

- **The script elevates with `sudo` automatically**; AUR/build steps run as your
  real user. Never run yay/makepkg as root yourself.
- **`-A` and `-S` are read-only** — they query APIs, read caches, and write only
  the report/snapshot files. They never install, remove, or build anything.
- **Flags are signals, not verdicts.** Don't panic on a lone `RECENTLY-CHANGED`.
  Weigh AGE + maintainer changes + votes + scan results together.
- **A clean `-S` scan is not absolute.** IOC lists only cover *disclosed*
  campaigns. Absence of a match ≠ proof of safety.
- **Network-dependent.** `-A`/`-S` need connectivity to the AUR RPC and GitHub.
  A failed IOC fetch degrades coverage and is reported — it is not silently
  ignored.
- **`--all` updates AUR via yay, but always with review.** The default `-u`
  backend is yay with its diff/edit menus enabled, so even an unattended-looking
  run stops and shows you every PKGBUILD change before building — a poisoned
  recipe can't slip through silently. For a fully non-interactive, repos-only
  update use `-u -P`.
- **The security checks are opt-in.** `-A` and `-S` never run as part of `--all`;
  request them explicitly. Run them *before* an AUR upgrade for the most
  protection.
