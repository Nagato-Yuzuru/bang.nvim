-- Entry points: the `<Plug>` operator, its repeat, and `:Bang`.
--
-- Adapters answer one question only -- which region and which command -- and
-- hand both to `require("bang").run()`. They also own what reaches the command
-- history; the engine records nothing.

local api = vim.api
local fn = vim.fn

local history = require("bang.history")
local notify = require("bang.notify")
local regions = require("bang.region")

local M = {}

local OPFUNC = "v:lua.require'bang.adapters'.opfunc"

---The mode character `visualmode()` reports, as a region kind.
local KINDS = { v = "char", V = "line", [regions.BLOCK] = "block" }

---The operator runs in one of two states: `fresh`, armed by the `<Plug>` expr
---and carrying what the selection looked like, or `repeat`, which is what `.`
---produces. Every read goes through `consume`, so no autocommand can turn a
---fresh invocation into a silent repeat of the previous command (F1, D3.2).
---@alias bang.Operator { state: "fresh", capture: { visual: boolean, ragged: boolean } }|{ state: "repeat" }
---@type bang.Operator
local operator = { state = "repeat" }

---@param capture table
local function arm(capture)
  operator = { state = "fresh", capture = capture }
end

local function disarm()
  operator = { state = "repeat" }
end

---@return bang.Operator
local function consume()
  local current = operator
  operator = { state = "repeat" }
  return current
end

---What `.` replays: the operator's own last command, and what Vim's redo does
---not hand an opfunc back about a block -- `$`, because curswant is a column
---again by then, and the width, because `']` stops at a short last line's own
---end. One value, so the parts cannot come apart (#24). The command is
---deliberately separate from the engine's `prev_cmd`, so a `:Bang` in between
---does not change what `.` does (D3.2).
---@type { cmd: string, ragged: boolean, width: integer|nil }|nil
local redo = nil

---Whether the buffer's last blockwise Visual selection was made with `$`. It is
---only readable while the selection is live -- curswant is a column again by
---the time a `:Bang` callback runs, and `'<`/`'>` cannot tell `$` from an
---overhang -- so it is recorded on the way out of the mode, the last moment it
---exists (R1, F4). It lives in the buffer, like the marks and `visualmode()`
---it completes: one slot for all buffers let a block in another buffer turn a
---`$` block back into a rectangle (#50).
local RAGGED = "bang_visual_ragged"

---Whether the live selection was made with `$`: curswant is maxcol exactly then.
---@return boolean
local function ragged_now()
  return fn.getcurpos()[5] == vim.v.maxcol
end

---Whether the buffer captured before an asynchronous prompt can still be
---written to (D4.3).
---@param buf integer
---@param tick integer
---@return boolean
local function still_writable(buf, tick)
  if not api.nvim_buf_is_valid(buf) then
    notify("bang: the buffer is gone, nothing was replaced")
    return false
  end
  if api.nvim_buf_get_changedtick(buf) ~= tick then
    notify("bang: the buffer changed while the command was being typed, nothing was replaced")
    return false
  end
  return true
end

---@param kind "char"|"line"|"block"
---@param anchor integer[] A `getpos()` result.
---@param cursor integer[]
---@param ragged boolean
---@return bang.Region
local function from_positions(kind, anchor, cursor, ragged)
  return {
    kind = kind,
    anchor = { lnum = anchor[2], col = anchor[3], off = anchor[4] },
    cursor = { lnum = cursor[2], col = cursor[3], off = cursor[4] },
    ragged = ragged,
  }
end

---The last Visual selection: `'<`/`'>` as Vim left them, which are raw ends, so
---the region is told what 'selection' says now -- which is what `gv` would
---reselect them as, whatever it said when they were made. `$` is the one thing
---they cannot say at all, and is passed in.
---@param kind "char"|"line"|"block"
---@param ragged boolean
---@return bang.Region
function M.region_of_selection(kind, ragged)
  local region = from_positions(kind, fn.getpos("'<"), fn.getpos("'>"), ragged)
  region.exclusive = vim.o.selection == "exclusive"
  return region
end

---The region the operator worked on. `'[`/`']` bracket the bytes it covered, so
---they are inclusive ends whatever 'selection' is. A blockwise `']` stops at a
---short last line's own end -- on 0.11 and 0.12 alike -- and cannot say how far
---right the block reached, so a `width` measured while the block was whole is
---handed over instead and the marks then name only the lines (D3.2).
---@param kind "char"|"line"|"block"
---@param ragged boolean
---@param width integer|nil Width in screen cells, for a `.` on a block.
---@return bang.Region
function M.region_of_marks(kind, ragged, width)
  local region = from_positions(kind, fn.getpos("'["), fn.getpos("']"), ragged)
  region.width = width
  return region
end

---A whole-line range, as `:[range]Bang` states one.
---@param line1 integer
---@param line2 integer
---@return bang.Region
function M.region_of_range(line1, line2)
  return {
    kind = "line",
    anchor = { lnum = line1, col = 1, off = 0 },
    cursor = { lnum = line2, col = 1, off = 0 },
  }
end

---Ask for a command, then run it on the region captured beforehand.
---@param buf integer
---@param region bang.Region
---@param visual boolean Whether the region came from a Visual selection.
---@param shape { ragged: boolean, width: integer|nil }|nil What `.` replays for a block; nil for any other region.
local function prompt(buf, region, visual, shape)
  local tick = api.nvim_buf_get_changedtick(buf)
  vim.ui.input({ prompt = "!", completion = "shellcmdline" }, function(input)
    if input == nil or input == "" then
      return -- Cancelled: no write, no history, repeat state untouched (D4.2).
    end
    if not still_writable(buf, tick) then
      return
    end
    local ok, _, expanded = require("bang").run(input, region, { buf = buf })
    -- Remembered once expanded, whether the run then succeeded, failed or was
    -- refused on its region: `%` keeps meaning the buffer the operator ran in
    -- (R17), and the repeat skips expansion rather than running it a second
    -- time (F5). The shape travels with the command as one value: written
    -- apart, a cancelled prompt left `.` with the last command and this
    -- selection's width (#24).
    if expanded then
      redo =
        { cmd = expanded, ragged = shape ~= nil and shape.ragged, width = shape and shape.width }
    end
    if ok then
      -- With the Visual range, so that running the entry again from `q:` acts
      -- on the selection (D9.2).
      history.record((visual and "'<,'>Bang " or "Bang ") .. input)
    end
  end)
end

---`<Plug>(bang-operator)`: set up `g@` and remember that this is a fresh
---invocation rather than a `.` repeat.
---@return string
function M.operator_expr()
  vim.o.operatorfunc = OPFUNC
  local mode = fn.mode()
  local visual = mode == "v" or mode == "V" or mode == regions.BLOCK
  -- `$` is only readable while the selection is live: by the time the operator
  -- function runs, curswant is back to a column (D5.3).
  arm({ visual = visual, ragged = mode == regions.BLOCK and ragged_now() })
  return "g@"
end

---`<Plug>(bang-line)`: the whole line, `[count]` lines with a count.
---@return string
function M.line_expr()
  vim.o.operatorfunc = OPFUNC
  arm({ visual = false, ragged = false })
  return "g@_"
end

---'operatorfunc'. Called by `g@` once the motion is known, and again by `.`.
---@param motion "char"|"line"|"block"
function M.opfunc(motion)
  local current = consume()
  local buf = api.nvim_get_current_buf()

  if current.state == "repeat" then
    -- Reuse the operator's own last command, without prompting. Vim rebuilds
    -- the region at the cursor and puts it in `'[`/`']`; what those cannot say
    -- about a block comes from the remembered shape, and with no shape -- the
    -- remembered run was not blockwise -- the marks are all of it, never
    -- `'<`/`'>`, which would name a cancelled selection (D3.2, #24).
    if not redo then
      return
    end
    local region = M.region_of_marks(motion, redo.ragged == true, redo.width)
    require("bang").run(redo.cmd, region, { buf = buf, expanded = true })
    return
  end

  -- A block goes through `'<`/`'>`, which Vim sets for a Visual selection and
  -- for a forced motion (`g!<C-v>j`) alike: they name both of the block's screen
  -- columns, while `']` is clamped to a short last line and loses the right one.
  local region, shape
  if motion == "block" then
    region = M.region_of_selection(motion, current.capture.ragged)
    shape = { ragged = current.capture.ragged, width = regions.block_width(buf, region) }
  else
    region = M.region_of_marks(motion, false)
  end
  prompt(buf, region, current.capture.visual, shape)
end

---Whether the `:` history holds this very invocation, and if so whether the
---user typed the plain Visual range. Returns nil when the entry belongs to
---something else -- a mapping, `<Cmd>`, `vim.cmd`, or an empty history (R2).
---@param opts table Callback argument of the user command.
---@return boolean|nil
local function typed_visual_range(opts)
  local entry = fn.histget(":", -1)
  local name = entry ~= "" and history.command_name(entry)
  if not name then
    return nil
  end
  local ok, parsed = pcall(api.nvim_parse_cmd, entry, {})
  if not ok or parsed.cmd ~= "Bang" or (parsed.bang or false) ~= (opts.bang or false) then
    return nil
  end
  local range = parsed.range or {}
  if #range ~= 2 or range[1] ~= opts.line1 or range[2] ~= opts.line2 then
    return nil
  end
  -- The argument text as typed, so that inner whitespace still matches.
  local args = entry:sub(name + #"Bang")
  if parsed.bang then
    args = args:gsub("^!", "")
  end
  if vim.trim(args) ~= vim.trim(opts.args or "") then
    return nil
  end
  -- `'<;'>` and `'<,'>+0` are different ranges from the plain marks, and are
  -- linewise like any other range (F6).
  return history.range_text(entry:sub(1, name - 1)):match("^'<%s*,%s*'>%s*$") ~= nil
end

---The region a `:Bang` call acts on (D3.3, R2). The last Visual selection is
---used only when the range covers exactly its lines, the selection was charwise
---or blockwise, and a typed command line does not say otherwise.
---@param opts table Callback argument of the user command.
---@param buf integer
---@return bang.Region region, boolean visual
local function command_region(opts, buf)
  local kind = KINDS[fn.visualmode()]
  local visual = opts.range == 2
    and opts.line1 == fn.line("'<")
    and opts.line2 == fn.line("'>")
    and (kind == "char" or kind == "block")
  if visual then
    local typed = typed_visual_range(opts)
    if typed ~= nil then
      visual = typed
    end
  end

  if not visual then
    return M.region_of_range(opts.line1, opts.line2), false
  end
  return M.region_of_selection(kind, kind == "block" and vim.b[buf][RAGGED] == true), true
end

---`:Bang[!] [cmd]`. Without a command, pick one from the history (D9.4).
---@param opts table Callback argument of the user command.
function M.command(opts)
  local buf = api.nvim_get_current_buf()
  local region, visual = command_region(opts, buf)
  local run_opts = { bang = opts.bang, buf = buf }
  local args = vim.trim(opts.args or "")
  if args ~= "" then
    require("bang").run(args, region, run_opts)
    return
  end

  local items = require("bang").history()
  if #items == 0 then
    notify("bang: no command has been run through :Bang yet", vim.log.levels.WARN)
    return
  end
  local tick = api.nvim_buf_get_changedtick(buf)
  vim.ui.select(items, { prompt = "Bang history" }, function(choice)
    if choice == nil or choice == "" then
      return
    end
    if not still_writable(buf, tick) then
      return
    end
    if require("bang").run(choice, region, run_opts) then
      -- Recorded like any other run, so the choice moves to the top (R15).
      history.record((visual and "'<,'>Bang " or "Bang ") .. choice)
    end
  end)
end

local DEFAULT_KEYMAPS = {
  { modes = { "n", "x" }, lhs = "g!", rhs = "<Plug>(bang-operator)" },
  { modes = { "n" }, lhs = "g!!", rhs = "<Plug>(bang-line)" },
}

---The global mapping for `lhs`, ignoring buffer-local ones (`maparg()` would
---prefer those).
---@param mode string
---@param lhs string
---@return table|nil
local function global_map(mode, lhs)
  for _, map in ipairs(api.nvim_get_keymap(mode)) do
    if map.lhs == lhs then
      return map
    end
  end
end

---The default keys, each with the global mapping that holds it right now.
---`rhs` is the `<Plug>` name the plugin would create; `map` is what
---`nvim_get_keymap()` reports for the key, or nil when nothing owns it.
---`default_keymaps()` creates and removes the keys from this list, and
---`:checkhealth bang` judges them by it, so the two cannot disagree (#17).
---@return { mode: string, lhs: string, rhs: string, map: table|nil }[]
function M.default_keymap_state()
  local state = {}
  for _, map in ipairs(DEFAULT_KEYMAPS) do
    for _, mode in ipairs(map.modes) do
      state[#state + 1] =
        { mode = mode, lhs = map.lhs, rhs = map.rhs, map = global_map(mode, map.lhs) }
    end
  end
  return state
end

---Create or remove the default `g!` / `g!!` keymaps. A key already mapped by
---the user is left alone, and only a mapping that is still ours is removed (R7).
---@param enable boolean
function M.default_keymaps(enable)
  for _, key in ipairs(M.default_keymap_state()) do
    if enable then
      if not key.map then
        vim.keymap.set(key.mode, key.lhs, key.rhs, {
          remap = true,
          desc = "Filter through a shell command",
        })
      end
    elseif key.map and key.map.rhs == key.rhs then
      pcall(vim.keymap.del, key.mode, key.lhs)
    end
  end
end

---Autocommands that watch what the keyboard is doing: whether a blockwise
---Visual selection was made with `$` (R1), and when an operator was abandoned
---so that `.` does not turn into a prompt (R3).
function M.setup_autocmds()
  local group = api.nvim_create_augroup("bang", { clear = true })
  api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = regions.BLOCK .. ":*",
    callback = function()
      -- Leaving the mode is the last moment `$` is readable, and curswant
      -- survives even the `<Esc>` that ends a `:normal!` block (F4). Every block
      -- records, so a `$` one cannot leave its flag behind for the next.
      vim.b[api.nvim_get_current_buf()][RAGGED] = ragged_now()
    end,
  })
  api.nvim_create_autocmd("ModeChanged", {
    group = group,
    -- Only the return to Normal mode ends the operator. `no:nov` and friends
    -- are forced motions (`g!v`) and `no:c` is a search motion (`g!/pat`), and
    -- both fire *before* the operator function runs -- disarming there would
    -- turn a fresh `g!` into a silent repeat (F1).
    pattern = "no*:n",
    callback = disarm,
  })
end

return M
