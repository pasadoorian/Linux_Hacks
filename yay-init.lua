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

-- Packages you know legitimately use Node/Electron tooling (suppress warnings):
local ALLOW = {
  ["mailspring"] = true,
}

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
    if ALLOW[event.match] then return end

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
