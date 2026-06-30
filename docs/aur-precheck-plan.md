# Plan: RPC-backed install-time AUR warnings

**Status:** planned, not started (saved 2026-06-30).
**Goal:** when installing/upgrading an AUR package, warn (advisory, never block)
if it is **orphaned**, **out-of-date**, **stale** (not updated in N days), or on
the **live compromised accounts/packages lists** — in addition to the existing
PKGBUILD/`.install` build-logic scan in `yay-init.lua`.

## Background / context

Two mechanisms exist today:

- **Install-time** — the `~/.config/yay/init.lua` `AURPreInstall` hook. Today it
  only scans the PKGBUILD + `.install` text for build-logic patterns
  (`npm install`, `curl … | sh`, 4 hard-coded IOC names). No network call, so it
  is blind to orphan status, the live compromised list, and staleness.
- **Audit-time** — `update.sh -A` / `-S`. These *do* check orphan/OOD/age and the
  live IOC lists, but only against **already-installed** packages, explicitly,
  after the fact.

This plan brings the audit intelligence to the moment of install.

### What "the AUR RPC" is
The AUR's HTTP/JSON metadata API: `https://aur.archlinux.org/rpc/v5/info?arg[]=<pkg>`
returns `Maintainer` (null = orphaned), `LastModified` (last package update,
unix ts), `OutOfDate` (null or flag timestamp), `NumVotes`, `Version`, etc.
`update.sh`'s `aur_query_rpc` already uses it. "RPC-backed" = the hook makes this
live query for the package being installed and warns on the answer.

### Key technical catch (why M0 exists)
yay v13 runs hooks in embedded Lua (gopher-lua): **no built-in HTTP, no JSON
parser, `io.popen` usually unavailable**. So the hook can't curl the RPC itself.
Realistic pattern: the Lua hook **shells out** via `os.execute` to a small bash
helper that does curl + JSON and prints warnings — Lua stays thin, all real logic
lives in testable bash. (Local yay confirmed: v13.0.1.)

## Milestones

### M0 — Spike: how the hook reaches the network (de-risk)
- Verify yay v13 Lua: does `os.execute` work? can we write curl output to a temp
  file and read it back with `io.open`? is `io.popen` available?
- Decide the integration mechanism (expected: `os.execute("helper > tmpfile")`
  then read tmpfile).
- **Exit criteria:** a tiny PoC hook that runs an external command and reads its
  output during a throwaway AUR install. If `os.execute` is blocked too, fall
  back to a thin `yay` shell wrapper (documented alternative).

### M1 — Extract a shared AUR library (refactor, no behavior change)
- Move `aur_query_rpc` + `aur_fetch_bad_accounts/packages/npm` out of `update.sh`
  into `lib/aur-common.sh`; `update.sh` sources it.
- **Exit criteria:** existing bats suite passes unchanged (proves behavior-preserving).

### M2 — Build `aur-precheck.sh <pkg>` (the helper)
- One RPC call → warn on **orphan / out-of-date / stale-age / not-found-in-AUR**;
  cross-reference the **live compromised accounts + packages** lists.
- Honors `LUA_ALLOWLIST` (skip trusted pkgs), a configurable age threshold, short
  network timeouts, an **IOC cache with TTL** (bulk upgrade doesn't re-fetch per
  package), and **degrades silently** offline. Always exits 0 (advisory).
- **Exit criteria:** `aur-precheck.sh somepkg` prints correct warnings vs fixtures.

### M3 — Wire the hook to the helper
- In `AURPreInstall`, call `aur-precheck.sh "$pkg"` via the M0 mechanism, print
  its output as warnings, and **keep** the existing build-logic scan. Graceful
  no-op if helper/curl missing. Never aborts.
- **Exit criteria:** installing a known orphan/stale test pkg surfaces the warning
  before yay's diff menu.

### M4 — Tests
- bats for `aur-precheck.sh` (reuse existing stubs/fixtures): orphan, OOD, stale,
  compromised account, compromised package, not-found, offline-degrade,
  allowlisted, cache hit/miss.
- Lua tests for the hook shim: mock `os.execute` to return canned warnings; assert
  they print, the build-logic scan still runs, and it never aborts.
- Wire into `tests/run-tests.sh`.
- **Exit criteria:** full suite green.

### M5 — Config, docs, deploy
- New config knobs in `update.conf.example`: `AUR_PRECHECK=true|false`,
  `AUR_PRECHECK_MAX_AGE_DAYS`, `AUR_IOC_CACHE_TTL`.
- Update `UPDATE_README.md` + `tests/README.md`; redeploy live
  `~/.config/yay/init.lua` from the repo copy; commit + push.

## Cross-cutting notes
- **Performance:** the hook fires for *every* AUR pkg in an upgrade (incl. deps).
  Mitigated by IOC cache + per-call timeout; `AUR_PRECHECK` toggle disables it for
  fast bulk upgrades. Main trade-off to weigh.
- **Philosophy preserved:** advisory only — warns, never blocks; yay's diff/edit
  menu still runs.

## Open decisions (not needed to start M0)
1. **M1 shared-lib refactor** (recommended — no logic drift, test-covered) vs. a
   self-contained `aur-precheck.sh` that duplicates a minimal RPC/IOC subset.
2. **Default for `AUR_PRECHECK`** — on by default (safer) vs. off (faster
   upgrades, opt-in).
