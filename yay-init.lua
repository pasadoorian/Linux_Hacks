-- ~/.config/yay/init.lua
-- Advisory AUR supply-chain tripwire — WARN ONLY, never blocks an install.
-- Scans each AUR PKGBUILD and its .install hook for the build-time patterns
-- used by the June 2026 "Atomic Arch" attacks and prints a warning.
-- yay still shows its normal diff/edit menu afterward, where you decide.

-- Case-insensitive plain substrings (matched literally, no Lua-pattern magic):
local SUSPICIOUS = {
  "npm install", "bun install", "bun add", "pnpm install", "yarn add",
  "| sh", "|sh", "| bash", "|bash",
  "atomic-lockfile", "js-digest", "lockfile-js", "nextfile-js",  -- known IOCs
}

-- Allowlist of packages that legitimately use Node/Electron tooling (their
-- warnings are suppressed). The source of truth is update.sh's LUA_ALLOWLIST,
-- which it writes to ~/.config/yay/allowlist.txt (one name/glob per line, '#'
-- comments allowed). If that file is absent (hook used standalone), we fall
-- back to a minimal built-in list.
local function load_allow(path)
  local allow = {}
  if not path then
    local home = os.getenv("HOME")
    path = home and (home .. "/.config/yay/allowlist.txt")
  end
  local f = path and io.open(path, "r")
  if f then
    for raw in f:lines() do
      local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
      if line ~= "" and not line:match("^#") then
        allow[#allow + 1] = line
      end
    end
    f:close()
    return allow                 -- honor the synced file as-is (may be empty)
  end
  return { "mailspring" }        -- file missing: built-in fallback
end

local ALLOW = load_allow()

-- Translate a shell-style glob into an anchored Lua pattern (escape Lua magic
-- chars except '*', then map '*' -> '.*').
local function glob_to_pat(glob)
  local p = glob:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%1")
  p = p:gsub("%*", ".*")
  return "^" .. p .. "$"
end

local function is_allowed(name)
  for _, pat in ipairs(ALLOW) do
    if name == pat then return true end                       -- exact
    if pat:find("*", 1, true) and name:match(glob_to_pat(pat)) then
      return true                                             -- glob
    end
  end
  return false
end

local function warn(msg)
  io.stderr:write("\n  [yay-tripwire WARNING] " .. msg .. "\n")
end

-- Return the list of needles found in `text`.
local function scan(text)
  local hits, hay = {}, (text or ""):lower()
  for _, needle in ipairs(SUSPICIOUS) do
    if hay:find(needle, 1, true) then        -- plain find, literal match
      hits[#hits + 1] = needle
    end
  end
  return hits
end

yay.create_autocmd("AURPreInstall", {
  desc = "Advisory scan of PKGBUILD + .install for supply-chain patterns",
  callback = function(event)
    if is_allowed(event.match) then return end

    -- Always scan the PKGBUILD text from the payload.
    local files = { PKGBUILD = event.data.pkgbuild }

    -- Best-effort: also scan the .install hook if we can find it in the repo dir.
    local dir = event.data.dir
    if dir then
      local declared = (event.data.pkgbuild or ""):match("install=[\"']?([%w%._%-]+)")
      for _, name in ipairs({ declared, event.match .. ".install" }) do
        if name then
          local f = io.open(dir .. "/" .. name, "r")
          if f then files[name] = f:read("*a"); f:close() end
        end
      end
    end

    -- Warn on any matches — never abort.
    for fname, text in pairs(files) do
      local hits = scan(text)
      if #hits > 0 then
        warn(string.format("%s: %s contains %s — review before installing.",
          event.match, fname, table.concat(hits, ", ")))
      end
    end
  end,
})

-- Test hook: when loaded by the suite (with _G.__YAY_TEST set) expose the
-- file-local helpers so they can be unit-tested. No effect under yay.
if rawget(_G, "__YAY_TEST") then
  return {
    scan = scan,
    is_allowed = is_allowed,
    glob_to_pat = glob_to_pat,
    load_allow = load_allow,
  }
end
