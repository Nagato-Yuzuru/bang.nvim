-- Acceptance tests for `:checkhealth bang` (#17).
--
-- The report is read the way a user reads it: `:checkhealth bang` is run in the
-- child and the lines of the health buffer are inspected. Only the level word
-- ("OK", "WARNING", "ERROR") is matched, never the decoration around it, which
-- differs between Neovim versions.

local H = dofile("tests/helpers.lua")

local eq, neq = MiniTest.expect.equality, MiniTest.expect.no_equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      H.setup_child(child)
    end,
    post_once = child.stop,
  },
})

--- Run `:checkhealth bang` and return the lines of the report it leaves behind.
local function report(c)
  c.cmd("checkhealth bang")
  return c.api.nvim_buf_get_lines(0, 0, -1, false)
end

--- The first report line mentioning `text`, or nil.
local function line(lines, text)
  for _, l in ipairs(lines) do
    if l:find(text, 1, true) then
      return l
    end
  end
end

--- The level the report gives the line mentioning `text`.
---
--- "INFO" is what a `vim.health.info()` line looks like: a message with no
--- level word in front of it. nil when nothing in the report mentions `text`,
--- which fails the comparison with the expected level.
local function level(lines, text)
  local found = line(lines, text)
  if found == nil then
    return nil
  end
  local prefix = found:sub(1, found:find(text, 1, true) - 1)
  for _, name in ipairs({ "ERROR", "WARNING", "OK" }) do
    if prefix:find(name, 1, true) then
      return name
    end
  end
  return "INFO"
end

-- A default install ---------------------------------------------------------

T["#17 a default install reports every check as healthy"] = function()
  local r = report(child)
  eq(level(r, "Neovim"), "OK")

  eq(level(r, "vim.g.bang:"), "OK")
  local cfg = line(r, "vim.g.bang:")
  for _, option in ipairs({ "on_error", "timeout", "keymaps = true", "expand_bang" }) do
    neq(cfg:find(option, 1, true), nil, { fail_reason = "the effective " .. option })
  end

  eq(level(r, "g! (Normal) is mapped to <Plug>(bang-operator)"), "OK")
  eq(level(r, "g! (Visual) is mapped to <Plug>(bang-operator)"), "OK")
  eq(level(r, "g!! (Normal) is mapped to <Plug>(bang-line)"), "OK")

  eq(level(r, "is executable"), "OK")
  local shell = line(r, "is executable")
  neq(shell:find("/bin/sh", 1, true), nil, { fail_reason = "the report must name 'shell'" })
  neq(shell:find("shellcmdflag", 1, true), nil, { fail_reason = "'shellcmdflag' alongside" })
end

-- The keys ------------------------------------------------------------------

T["#17 a key another mapping owns is reported as skipped, with that mapping"] = function()
  -- The silent skip of R7: the plugin is installed and the key does something
  -- else, which the report is the only place to find out.
  H.setup_child(child, {
    pre_plugin = [[vim.keymap.set("n", "g!", "<Plug>(other-plugin)", { desc = "user mapping" })]],
  })
  local r = report(child)

  eq(level(r, "g! (Normal)"), "WARNING")
  local skipped = line(r, "g! (Normal)")
  neq(skipped:find("<Plug>(other-plugin)", 1, true), nil, { fail_reason = "the foreign rhs" })
  neq(skipped:find("user mapping", 1, true), nil, { fail_reason = "the foreign desc" })

  -- Only Normal mode was taken, so the Visual half is still the plugin's.
  eq(level(r, "g! (Visual) is mapped to <Plug>(bang-operator)"), "OK")
end

T["#17 keymaps = false reports the default keys as off, not as missing"] = function()
  H.setup_child(child, { config = { keymaps = false } })
  local r = report(child)
  for _, key in ipairs({ "g! (Normal)", "g! (Visual)", "g!! (Normal)" }) do
    eq(level(r, key), "INFO", { fail_reason = key .. " is a deliberate absence, not a problem" })
    neq(line(r, key):find("keymaps = false", 1, true), nil, { fail_reason = key .. ": the reason" })
  end
end

T["#17 default keys the plugin has not created yet are a warning"] = function()
  -- What a lazy loader that has not sourced plugin/bang.lua yet looks like.
  H.setup_child(child, { plugin = false })
  local r = report(child)
  for _, key in ipairs({ "g! (Normal)", "g! (Visual)", "g!! (Normal)" }) do
    eq(level(r, key), "WARNING", { fail_reason = key })
  end
  neq(
    line(r, "g! (Normal)"):find("keymaps = true", 1, true),
    nil,
    { fail_reason = "the report must say the key was asked for" }
  )
end

-- The configuration ---------------------------------------------------------

T["#17 an invalid vim.g.bang is an error carrying the reason"] = function()
  H.setup_child(child, { config = { nope = true } })
  local r = report(child)

  eq(level(r, "vim.g.bang has no option"), "ERROR")
  neq(
    line(r, "vim.g.bang has no option"):find("nope", 1, true),
    nil,
    { fail_reason = "the message must name the offending key" }
  )
  -- The plugin loads with the defaults after a bad `vim.g.bang`, so the keys
  -- are judged against those rather than reported as missing.
  eq(level(r, "g! (Normal) is mapped to <Plug>(bang-operator)"), "OK")
end

-- The shell -----------------------------------------------------------------

T["#17 a 'shell' that is not executable is an error"] = function()
  child.o.shell = "/definitely/not/a/shell"
  local r = report(child)
  eq(level(r, "not executable"), "ERROR")
  neq(line(r, "not executable"):find("/definitely/not/a/shell", 1, true), nil)
end

T["#17 a 'shell' carrying arguments is checked by its program alone"] = function()
  -- `csh -f`: the argument is not part of the path to test for (R6).
  H.use_log_shell(child, "-c", H.fixtures .. "/log_shell.sh -f")
  eq(level(report(child), "is executable"), "OK")
end

return T
