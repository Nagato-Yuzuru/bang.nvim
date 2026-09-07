-- `:checkhealth bang`: why the plugin does, or does not, work here.
--
-- The report has to run where the plugin does not, so the version gate below
-- uses only what predates 0.11, and nothing here assumes `plugin/bang.lua` was
-- sourced -- a lazy loader may still be holding it back (#17).

local health = vim.health
-- `start()`, `ok()`, `warn()`, `info()` and `error()` are the 0.10 names. The
-- version gate has to speak on older Neovims too, where only the `report_*()`
-- names exist, so the whole report goes through whichever set is there.
local report = {
  start = health.start or health.report_start,
  ok = health.ok or health.report_ok,
  warn = health.warn or health.report_warn,
  info = health.info or health.report_info,
  error = health.error or health.report_error,
}

local M = {}

-- The modes the default keys live in, spelled the way `:map` talks about them.
local MODES = { n = "Normal", x = "Visual" }

---The running Neovim, as `major.minor.patch`. Built by hand rather than by
---`tostring(vim.version())`, which only became a Version object in 0.10.
---@return string
local function neovim_version()
  local v = vim.version()
  return ("%d.%d.%d"):format(v.major, v.minor, v.patch)
end

---The effective options, one `name = value` per option the plugin has, taken
---from the defaults so that a new option shows up here without being listed
---twice.
---@param defaults table
---@param cfg table
---@return string
local function options(defaults, cfg)
  local names = vim.tbl_keys(defaults)
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do
    parts[#parts + 1] = ("%s = %s"):format(name, vim.inspect(cfg[name]))
  end
  return table.concat(parts, ", ")
end

---How a foreign mapping presents itself: its right-hand side, plus its `desc`
---when it has one, which is often the only readable clue to who owns the key.
---@param map table A `nvim_get_keymap()` entry.
---@return string
local function describe(map)
  local rhs = map.rhs
  if rhs == nil or rhs == "" then
    rhs = map.callback ~= nil and "a Lua function" or "nothing"
  end
  return map.desc ~= nil and ("%s (%s)"):format(rhs, map.desc) or rhs
end

---@param cfg bang.Config The effective configuration, or the defaults.
local function check_keymaps(cfg)
  report.start("Default keymaps")
  for _, key in ipairs(require("bang.adapters").default_keymap_state()) do
    local name = ("%s (%s)"):format(key.lhs, MODES[key.mode] or key.mode)
    if key.map ~= nil and key.map.rhs == key.rhs then
      report.ok(("%s is mapped to %s"):format(name, key.rhs))
    elseif not cfg.keymaps then
      report.info(("%s was not mapped by bang.nvim: keymaps = false"):format(name))
    elseif key.map ~= nil then
      -- The silent skip issue #17 is about: the plugin looks installed, and
      -- the key does something else entirely.
      local owner = describe(key.map)
      report.warn(
        ("%s was already mapped to %s, so bang.nvim left it alone"):format(name, owner),
        ("Map %s to a free key to get the plugin back."):format(key.rhs)
      )
    else
      report.warn(
        ("%s is not mapped, although keymaps = true"):format(name),
        "plugin/bang.lua has not been sourced yet; a lazy loader may be deferring it."
      )
    end
  end
end

local function check_shell()
  report.start("Shell")
  -- Split the way the plugin splits it before spawning, so that an escaped
  -- space or a quoted path is read here exactly as `run()` reads it (R6).
  local program = require("bang.exec").shell_words()[1] or ""
  local where = ("'shell' is %s, 'shellcmdflag' is %s"):format(
    vim.inspect(vim.o.shell),
    vim.inspect(vim.o.shellcmdflag)
  )
  if vim.fn.executable(program) == 1 then
    report.ok(("%s is executable (%s)"):format(vim.inspect(program), where))
  else
    report.error(
      ("%s is not executable (%s)"):format(vim.inspect(program), where),
      "Set 'shell' to a program that exists; no command can run until then."
    )
  end
end

function M.check()
  report.start("bang.nvim")

  -- The same gate as `plugin/bang.lua`. Below it the plugin registers nothing,
  -- so there is no configuration, keymap or shell of ours left to report on.
  if vim.fn.has("nvim-0.11") == 0 then
    report.error(
      ("Neovim %s, but bang.nvim requires 0.11 or newer"):format(neovim_version()),
      "The plugin is inactive: it registers no :Bang, no <Plug> mappings and no keys."
    )
    return
  end
  report.ok(("Neovim %s"):format(neovim_version()))

  report.start("Configuration")
  local config = require("bang.config")
  local cfg, err = config.get()
  if cfg then
    report.ok(("vim.g.bang: %s"):format(options(config.defaults, cfg)))
  else
    report.error(err, "bang.nvim falls back to its defaults until vim.g.bang is fixed.")
    -- Which is what `plugin/bang.lua` does, so the keys below are judged
    -- against the configuration the plugin actually loaded with.
    cfg = config.defaults
  end

  check_keymaps(cfg)
  check_shell()
end

return M
