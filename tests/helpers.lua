-- Shared helpers for the bang.nvim acceptance suite.
--
-- Every case runs in a child Neovim so that keymaps, the command line and the
-- `:` history behave exactly as they do for a user. Tests observe the plugin
-- only through its public contract (DESIGN.md §3.4, §3.1, §3.3, §8):
-- `require("bang")`, the `<Plug>` mappings, `:Bang` and `vim.g.bang`. No
-- internal module is ever named here.
--
-- Load with `local H = dofile("tests/helpers.lua")` from the repository root.

local Helpers = {}

Helpers.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
Helpers.fixtures = Helpers.root .. "/tests/fixtures"

--- Stands in for `vim.v.maxcol` inside a region column (DESIGN.md §3.4: "to end
--- of line"). The real value cannot be handed to the child as-is without the
--- parent and the child agreeing on it, so `Helpers.run()` substitutes it there.
Helpers.MAXCOL = -1

-- Buffers ------------------------------------------------------------------

function Helpers.set_lines(child, lines)
  child.api.nvim_buf_set_lines(0, 0, -1, true, lines)
end

function Helpers.get_lines(child)
  return child.api.nvim_buf_get_lines(0, 0, -1, true)
end

-- Regions ------------------------------------------------------------------

--- Build the public region table of DESIGN.md §3.4.
---
--- Columns are 1-based byte columns in the `getregionpos()` vocabulary;
--- `Helpers.MAXCOL` means "to end of line".
function Helpers.region(rtype, start_lnum, start_col, finish_lnum, finish_col)
  return {
    type = rtype,
    start = { lnum = start_lnum, col = start_col },
    finish = { lnum = finish_lnum, col = finish_col },
  }
end

function Helpers.charwise(start_lnum, start_col, finish_lnum, finish_col)
  return Helpers.region("v", start_lnum, start_col, finish_lnum, finish_col)
end

function Helpers.linewise(start_lnum, finish_lnum)
  return Helpers.region("V", start_lnum, 1, finish_lnum, Helpers.MAXCOL)
end

function Helpers.blockwise(start_lnum, start_col, finish_lnum, finish_col)
  return Helpers.region("\22", start_lnum, start_col, finish_lnum, finish_col)
end

--- What the built-in `!` leaves in the buffer for the output `a\rb\n`: with
--- 'noshelltemp' (default since 0.12) it reads a pipe and splits on the bare
--- \r; with 'shelltemp' (0.11 default) a temp file keeps it inside the line.
function Helpers.builtin_cr_lines(child)
  return child.o.shelltemp and { "a\rb" } or { "a", "b" }
end

-- Stubs --------------------------------------------------------------------

--- Capture everything the plugin notifies (DESIGN.md §6.4, §6.5).
function Helpers.stub_notify(child)
  child.lua([[
    _G.bang_notifications = {}
    vim.notify = function(msg, level)
      table.insert(_G.bang_notifications, { msg = msg, level = level })
    end
    vim.notify_once = vim.notify
  ]])
end

function Helpers.reset_notifications(child)
  child.lua("_G.bang_notifications = {}")
end

--- Notifications seen so far, after letting the event loop run.
---
--- DESIGN.md §6.5 requires them to be emitted through `vim.schedule`, so they
--- are not there yet when the call that triggered them returns.
function Helpers.notifications(child)
  child.lua("vim.wait(50)")
  return child.lua_get("_G.bang_notifications")
end

--- Notifications seen so far *without* draining the loop.
function Helpers.notifications_now(child)
  return child.lua_get("_G.bang_notifications")
end

--- Replace `vim.ui.input` (DESIGN.md §4).
---
--- `answers` is consumed one entry per prompt; `false` stands for a cancelled
--- prompt (the callback is handed `nil`). Each prompt's `opts` is recorded in
--- `_G.bang_prompts`, readable through `Helpers.prompts()`.
---
--- `spec.defer` runs the callback from `vim.schedule`, which is how UI plugins
--- such as dressing.nvim and snacks.nvim answer (DESIGN.md §4.3).
--- `spec.between` is Lua source run after the prompt and before the callback --
--- the stale-buffer case of §4.3.
function Helpers.stub_input(child, answers, spec)
  spec = spec or {}
  local deliver = "cb(a)"
  if spec.defer then
    deliver = ("vim.schedule(function() %s cb(a) end)"):format(spec.between or "")
  end
  child.lua(
    ([[
      local answers = ...
      _G.bang_prompts, _G.bang_answers, _G.bang_prompt_n = {}, answers, 0
      vim.ui.input = function(o, cb)
        table.insert(_G.bang_prompts, o or {})
        _G.bang_prompt_n = _G.bang_prompt_n + 1
        local a = _G.bang_answers[_G.bang_prompt_n]
        if a == false then a = nil end
        %s
      end
    ]]):format(deliver),
    { answers }
  )
end

function Helpers.prompts(child)
  return child.lua_get("_G.bang_prompts")
end

function Helpers.prompt_count(child)
  return child.lua_get("#_G.bang_prompts")
end

--- Replace `vim.ui.select` (DESIGN.md §9.4).
---
--- `choice` is the item to pick, or `false` to dismiss the picker. Every call is
--- recorded in `_G.bang_selects`.
function Helpers.stub_select(child, choice)
  child.lua(
    [[
      local choice = ...
      _G.bang_selects = {}
      vim.ui.select = function(items, o, cb)
        table.insert(_G.bang_selects, { items = items, opts = o or {} })
        if choice == false then return cb(nil) end
        for i, item in ipairs(items) do
          if item == choice then return cb(item, i) end
        end
        cb(nil)
      end
    ]],
    { choice }
  )
end

function Helpers.selects(child)
  return child.lua_get("_G.bang_selects")
end

--- The global mapping for `lhs` in `mode`, or `nil`.
---
--- `maparg()` prefers a buffer-local mapping, which is exactly the distinction
--- R7 turns on, so the keymap lists are read directly.
function Helpers.global_map(child, mode, lhs)
  return Helpers.find_map(child, "vim.api.nvim_get_keymap(mode)", mode, lhs)
end

--- The buffer-local mapping for `lhs` in `mode`, or `nil`.
function Helpers.buffer_map(child, mode, lhs)
  return Helpers.find_map(child, "vim.api.nvim_buf_get_keymap(0, mode)", mode, lhs)
end

function Helpers.find_map(child, getter, mode, lhs)
  local found = child.lua(
    ([[
      local mode, lhs = ...
      for _, m in ipairs(%s) do
        if m.lhs == lhs then
          return { rhs = m.rhs, desc = m.desc, expr = m.expr }
        end
      end
      return nil
    ]]):format(getter),
    { mode, lhs }
  )
  if found == nil or found == vim.NIL then
    return nil
  end
  return found
end

-- The plugin ---------------------------------------------------------------

--- Start a clean child Neovim with a deterministic environment.
---
--- `opts.config` is written to `vim.g.bang` before `plugin/bang.lua` loads, which
--- is the only way to reach the load-time options (DESIGN.md §8.1: "Options are
--- read at call time, except `keymaps` at load").
--- `opts.plugin = false` skips sourcing `plugin/bang.lua` (the runner uses
--- `--noplugin`, so nothing is sourced by default).
--- `opts.pre_plugin` is Lua source run after `vim.g.bang` is set and before the
--- plugin loads -- the only way to have a user mapping already in place when the
--- default keymaps are considered (R7).
function Helpers.setup_child(child, opts)
  opts = opts or {}
  -- `--noplugin` matters: without it the child sources `plugin/bang.lua` during
  -- startup, before `vim.g.bang` can be set, and the load-time `keymaps` option
  -- (DESIGN.md §8.1) could never be exercised.
  child.restart({ "--noplugin", "-u", "tests/minimal_init.lua" })

  -- A tall command area keeps a message from turning into a hit-enter prompt,
  -- which would block the child.
  child.o.lines, child.o.columns, child.o.cmdheight = 40, 160, 10
  child.o.swapfile = false
  -- Results must not depend on the shell the developer happens to use.
  child.o.shell, child.o.shellcmdflag = "/bin/sh", "-c"

  Helpers.stub_notify(child)
  if opts.config ~= nil then
    child.lua("vim.g.bang = ...", { opts.config })
  end
  if opts.pre_plugin ~= nil then
    child.lua(opts.pre_plugin)
  end
  if opts.plugin ~= false then
    child.cmd("runtime plugin/bang.lua")
  end
  Helpers.require_bang(child, opts)
end

--- Precondition guard, not an assertion.
---
--- Before the implementation exists this is where every case stops, with
--- "module 'bang' not found". Without it, a case would go on to type `g!iw`
--- into a child that has no such mapping, leaving it in operator-pending mode
--- with a half-typed `:.,.!` on the command line.
function Helpers.require_bang(child, opts)
  opts = opts or {}
  child.lua("require('bang')")
  if opts.plugin == false then
    return
  end
  local missing = child.lua_get([[(function()
    local m = {}
    if vim.fn.exists(":Bang") ~= 2 then m[#m + 1] = ":Bang" end
    for _, lhs in ipairs({ "<Plug>(bang-operator)", "<Plug>(bang-line)" }) do
      if vim.tbl_isempty(vim.fn.maparg(lhs, "n", false, true)) then m[#m + 1] = lhs end
    end
    return m
  end)()]])
  if #missing > 0 then
    error("plugin/bang.lua registered neither " .. table.concat(missing, " nor "))
  end
end

function Helpers.setup(child, opts)
  child.lua("require('bang').setup(...)", { opts })
end

--- Call `require("bang").run()` (DESIGN.md §3.4) and return `{ ok, msg }`.
function Helpers.run(child, cmd, region, opts)
  return child.lua(
    [[
      local cmd, region, opts = ...
      if region ~= nil then
        if region.start.col == -1 then region.start.col = vim.v.maxcol end
        if region.finish.col == -1 then region.finish.col = vim.v.maxcol end
      end
      local ok, msg = require("bang").run(cmd, region, opts)
      return { ok = ok, msg = msg }
    ]],
    { cmd, region, opts }
  )
end

--- Like `Helpers.run`, but also reports whether the call threw.
---
--- R8 makes `run()` a single error channel: it returns `false, message` for every
--- runtime condition and never raises.
function Helpers.run_pcall(child, cmd, region, opts)
  return child.lua(
    [[
      local cmd, region, opts = ...
      if region ~= nil then
        if region.start.col == -1 then region.start.col = vim.v.maxcol end
        if region.finish.col == -1 then region.finish.col = vim.v.maxcol end
      end
      local called, ok, msg = pcall(require("bang").run, cmd, region, opts)
      if not called then
        return { threw = true, msg = tostring(ok) }
      end
      return { threw = false, ok = ok, msg = msg }
    ]],
    { cmd, region, opts }
  )
end

function Helpers.history(child)
  return child.lua_get("require('bang').history()")
end

-- Command line and history -------------------------------------------------

--- Type an Ex command the way a user does, so that `:` history is updated.
---
--- `:Bang` distinguishes a Visual selection from a line range by reading
--- `histget(":", -1)` (DESIGN.md §3.3), and only *typed* commands get there.
--- A bare `<` inside `nvim_input` starts key notation, hence the escape.
function Helpers.type_cmd(child, text)
  child.type_keys(":", (text:gsub("<", "<LT>")), "<CR>")
end

--- The whole `:` command-line history, oldest first.
function Helpers.cmd_history(child)
  return child.lua_get([[(function()
    local r = {}
    for i = 1, vim.fn.histnr(":") do
      r[#r + 1] = vim.fn.histget(":", i)
    end
    return r
  end)()]])
end

function Helpers.histadd(child, entries)
  child.lua(
    [[
      for _, e in ipairs(...) do
        vim.fn.histadd(":", e)
      end
    ]],
    { entries }
  )
end

-- The &shell fixture -------------------------------------------------------

--- Copy the logging fixture to `dest` and make it executable.
---
--- Used to place it behind a path containing a space, which `'shell'` can only
--- carry escaped (R6, `option-backslash`).
function Helpers.install_log_shell(child, dest)
  child.lua(
    [[
      local src, dest = ...
      vim.fn.mkdir(vim.fn.fnamemodify(dest, ":h"), "p")
      vim.fn.writefile(vim.fn.readfile(src, "b"), dest, "b")
      vim.fn.setfperm(dest, "rwxr-xr-x")
    ]],
    { Helpers.fixtures .. "/log_shell.sh", dest }
  )
end

--- Point `'shell'` at tests/fixtures/log_shell.sh (DESIGN.md §6.1).
---
--- The fixture records its argv and the exact bytes of its stdin, so the test
--- can read back what the plugin actually handed the shell instead of guessing
--- from the filtered text. Returns the log path.
--- `shell` overrides the `'shell'` value, so a test can hand over a value that
--- carries arguments or an escaped space (R6).
function Helpers.use_log_shell(child, shellcmdflag, shell)
  local log = child.lua_get("vim.fn.tempname()")
  child.lua(
    [[
      local shell, flag, log = ...
      vim.o.shell, vim.o.shellcmdflag = shell, flag
      vim.env.BANG_TEST_LOG = log
    ]],
    { shell or (Helpers.fixtures .. "/log_shell.sh"), shellcmdflag or "-c", log }
  )
  return log
end

--- Read back what `log_shell.sh` recorded: `{ cwd = "…", argv = { … }, stdin = "…" }`.
--- `stdin` is `nil` when the fixture was never invoked.
function Helpers.log_shell(child, log)
  local raw = child.lua_get(
    [[(function(p)
      local f = io.open(p, "rb")
      if f == nil then return nil end
      local s = f:read("*a")
      f:close()
      return s
    end)(...)]],
    { log }
  )
  if raw == nil or raw == vim.NIL then
    return { argv = {}, stdin = nil }
  end
  local head, stdin = raw:match("^(.-)%-%-stdin%-%-\n(.*)$")
  head = head or ""
  local argv = {}
  for arg in head:gmatch("argv\t([^\n]*)\n") do
    argv[#argv + 1] = arg
  end
  return { cwd = head:match("cwd\t([^\n]*)\n"), argv = argv, stdin = stdin }
end

return Helpers
