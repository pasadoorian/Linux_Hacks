-- Minimal zero-dependency assertion harness for the lua tests.
-- Usage: local T = dofile("tests/helpers/lua_harness.lua") ; T.eq(...) ; os.exit(T.report("name") and 0 or 1)

local M = { passed = 0, failed = 0 }

function M.eq(got, want, msg)
  if got == want then
    M.passed = M.passed + 1
  else
    M.failed = M.failed + 1
    io.write(string.format("not ok - %s\n  got:  %s\n  want: %s\n",
      msg or "?", tostring(got), tostring(want)))
  end
end

function M.ok(cond, msg)
  if cond then
    M.passed = M.passed + 1
  else
    M.failed = M.failed + 1
    io.write("not ok - " .. (msg or "?") .. "\n")
  end
end

function M.report(name)
  io.write(string.format("# %s: %d passed, %d failed\n",
    name or "lua", M.passed, M.failed))
  return M.failed == 0
end

return M
