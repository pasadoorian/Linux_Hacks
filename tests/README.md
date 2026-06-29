# Tests

Test suite for `update.sh` and `yay-init.lua` (the other repo scripts get
syntax + usage smoke checks). Bash is tested with [bats-core]; the lua hook with
a tiny zero-dependency harness.

## Running

```bash
./tests/run-tests.sh           # everything
./tests/run-tests.sh -v        # verbose bats output
./tests/run-tests.sh -f audit  # only bats tests whose name matches "audit"
```

First run fetches the vendored bats submodules automatically. To do it manually:

```bash
git submodule update --init --recursive
```

`shellcheck` is optional — installed, it runs (`pacman -S shellcheck`); absent,
it's skipped.

## Layout

```
tests/
  run-tests.sh         # orchestrates: bash -n, luac -p, shellcheck, bats, lua
  bats/                # vendored submodules: bats-core, bats-support, bats-assert, bats-file
  helpers/
    common.bash        # setup_update_env(): sandbox HOME, stub PATH, source update.sh
    lua_harness.lua    # ~30-line assert/report runner
  stubs/bin/           # mock pacman/curl/sudo/yay/... (PATH-shadow the real tools)
  fixtures/ioc/        # sample malicious accounts/packages/npm lists
  unit/                # *.bats unit tests for update.sh functions
  lint/                # bash -n / luac / shellcheck / usage smoke
  lua/                 # test_yay_init.lua
```

## How it works

### bats (bash)
A `.bats` file is bash with `@test "name" { ... }` blocks. bats runs each test
in its own subshell, so state never leaks between tests. The key idiom is
`run <cmd>`, which executes a command **without** failing the test on a non-zero
exit and captures `$status`, `$output`, and `$lines[]`. Assertions
(`assert_success`, `assert_output --partial`, `refute_output`, `assert_line`)
come from the `bats-assert` / `bats-support` helper libs. `setup()` /
`teardown()` run before/after every test.

### How update.sh is tested
`update.sh` self-elevates with `sudo` and runs `main` at the bottom, so it can't
be imported as-is. Two guards (added for testability) make it **sourceable**:
the root re-exec is skipped when sourced or when `UPDATE_SH_TEST=1`, and the
script `return`s before argument parsing when sourced. So `source update.sh`
loads **just the functions and default variables**.

`setup_update_env()` (in `helpers/common.bash`) then:
1. exports `UPDATE_SH_TEST=1` and a sandbox `USER_HOME` (a `mktemp -d`), so every
   file the script writes (`alien-pkgs.txt`, `aur-audit.txt`, the maintainer
   snapshot, the yay allowlist) lands in a throwaway dir;
2. prepends `tests/stubs/bin` to `PATH` so `pacman`, `yay`, `pamac`, `curl`,
   `sudo`, etc. resolve to **mocks** instead of the real tools;
3. sources `update.sh`.

The mocks log every invocation to `$STUB_LOG` (asserted via `stub_called`) and
serve fixture output for queries (`pacman -Qmq`, the AUR RPC, IOC lists). The
`curl` mock even emulates the AUR RPC by filtering the fixture to the requested
`arg[]=` packages, and honors `CURL_FAIL=1` to exercise offline paths. Tests
then call functions directly (`run aur_audit`, `run check_foreign_orphans <<<
$'y\nn'`) and assert on output, the stub log, and the sandbox files.

### lua
`yay-init.lua` exposes its file-local helpers when `_G.__YAY_TEST` is set
(`return { scan, is_allowed, glob_to_pat, load_allow }`) and `load_allow` takes
an optional path so file-reading is testable without touching real `$HOME`. The
test stubs the `yay` global to capture the `AURPreInstall` callback, then drives
it with synthetic events (replacing `io.stderr` to capture warnings).

## Adding a test
- New unit test: drop a `*.bats` file in `tests/unit/`, `load ../helpers/common`,
  and use `setup() { load_libs; setup_update_env; }`.
- Need a new external command mocked? Add an executable to `tests/stubs/bin`
  (symlink to `_noop` for record-only commands).

## Known limitations
- The config **owner-mismatch** branch needs root/fakeroot to construct a
  foreign-owned file, so it's `skip`ped on normal runs (the **world-writable**
  branch is fully tested).
- Tests run as your user, so `chown`-to-root effects aren't exercised (the logic
  is; the ownership change isn't).
- `supply_chain_check.sh` gets lint + usage smoke only.

[bats-core]: https://github.com/bats-core/bats-core
