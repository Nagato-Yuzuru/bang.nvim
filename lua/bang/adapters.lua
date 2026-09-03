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

---The operator runs in one of two states: `fresh`, armed by the `<Plug>` expr
---and carrying what the selection looked like, or `repeat`, which is what `.`
---produces. Every read goes through `consume`, so no autocommand can turn a
---fresh invocation into a silent repeat of the previous command (F1, D3.2).
---@alias bang.Operator { state: "fresh", capture: table }|{ state: "repeat" }
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

---The operator's own last command, reused by `.`. Deliberately separate from
---the engine's `prev_cmd`: a `:Bang` in between does not change what `.` does.
---@type string|nil
local repeat_cmd = nil

---@class bang.BlockGeometry
---@field anchor { lnum: integer, col: integer } Where CTRL-V was pressed (byte col + coladd).
---@field cursor { lnum: integer, col: integer } The moving corner (byte col + coladd).
---@field ragged boolean Whether `$` is active (curswant is maxcol).

---What the last blockwise Visual selection looked like while it was live. Both
---the `$` flag and the two corners are reset by the time a `:Bang` callback runs
----- and `'<`/`'>` reorder the corners by position, losing which column belongs
---to which -- so the geometry is recorded while the selection still exists (R1,
---D-2). `anchor`/`cursor` are present only when `CursorMoved` observed them; a
---`:normal!` block records just the `$` flag, and the marks supply the corners.
---@type { buf: integer, ragged: boolean, anchor?: table, cursor?: table }|nil
local block_record = nil

---The live blockwise selection's geometry, read while it is still the current
---mode. `getpos("v")` is the fixed corner, `getcurpos()` the moving one; both
---carry `coladd` for virtual space (F7), and curswant is maxcol exactly for `$`.
---@return bang.BlockGeometry
local function live_block()
  local anchor, cursor = fn.getpos("v"), fn.getcurpos()
  return {
    anchor = { lnum = anchor[2], col = anchor[3] + anchor[4] },
    cursor = { lnum = cursor[2], col = cursor[3] + cursor[4] },
    ragged = cursor[5] == vim.v.maxcol,
  }
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

---A blockwise `bang.Region` carrying the two corners as a `block` hint, so the
---engine derives the screen columns from the corners rather than from the
---reordered `'<`/`'>` marks (D-2). `start`/`finish` still carry the line range.
---@param geom bang.BlockGeometry
---@return bang.Region
local function block_region(geom)
  return {
    type = regions.BLOCK,
    start = { lnum = math.min(geom.anchor.lnum, geom.cursor.lnum), col = 1 },
    finish = { lnum = math.max(geom.anchor.lnum, geom.cursor.lnum), col = 1 },
    block = geom,
  }
end

---The block geometry from `'<`/`'>`, the only source left on a `.` repeat, when
---there is no live selection to read. The marks cannot tell `$` from an
---overhang, so a repeat is never ragged.
---@return bang.BlockGeometry
local function block_from_marks()
  local from, to = fn.getpos("'<"), fn.getpos("'>")
  return {
    anchor = { lnum = from[2], col = from[3] + from[4] },
    cursor = { lnum = to[2], col = to[3] + to[4] },
    ragged = false,
  }
end

---The region `g@` just marked out.
---@param buf integer
---@param motion "char"|"line"|"block"
---@param captured { visual: boolean, block: bang.BlockGeometry|nil }|nil
---@return bang.Region
local function operator_region(buf, motion, captured)
  local rtype = "v"
  if motion == "line" then
    rtype = "V"
  elseif motion == "block" then
    rtype = regions.BLOCK
  end
  if rtype == regions.BLOCK then
    -- `'[`/`']` describe the motion, not the block, so the geometry is the one
    -- captured live (or, on a `.` repeat, the marks as a fallback). Passing the
    -- two corners keeps each column with its own corner, which `'<`/`'>` lose on
    -- a short far line or a `$` block (D-2).
    return block_region(captured and captured.block or block_from_marks())
  end
  local from = api.nvim_buf_get_mark(buf, "[")
  local to = api.nvim_buf_get_mark(buf, "]")
  return {
    type = rtype,
    start = { lnum = from[1], col = from[2] + 1 },
    finish = { lnum = to[1], col = to[2] + 1 },
  }
end

---Ask for a command, then run it on the region captured beforehand.
---@param buf integer
---@param region bang.Region
---@param visual boolean Whether the region came from a Visual selection.
local function prompt(buf, region, visual)
  local tick = api.nvim_buf_get_changedtick(buf)
  vim.ui.input({ prompt = "!", completion = "shellcmdline" }, function(input)
    if input == nil or input == "" then
      return -- Cancelled: no write, no history, repeat state untouched (D4.2).
    end
    if not still_writable(buf, tick) then
      return
    end
    local ok, _, expanded = require("bang").run(input, region, { buf = buf })
    -- Remembered as the shell saw it, so `%` keeps meaning the buffer the
    -- operator ran in (R17); the repeat then skips expansion rather than
    -- running it a second time (F5).
    repeat_cmd = expanded or repeat_cmd
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
  -- The block's corners are only readable while the selection is live: by the
  -- time the operator function runs, `'<`/`'>` have reordered them and curswant
  -- is back to a column (D5.3, D-2).
  arm({ visual = visual, block = mode == regions.BLOCK and live_block() or nil })
  return "g@"
end

---`<Plug>(bang-line)`: the whole line, `[count]` lines with a count.
---@return string
function M.line_expr()
  vim.o.operatorfunc = OPFUNC
  arm({ visual = false })
  return "g@_"
end

---'operatorfunc'. Called by `g@` once the motion is known, and again by `.`.
---@param motion "char"|"line"|"block"
function M.opfunc(motion)
  local current = consume()
  local buf = api.nvim_get_current_buf()
  local region = operator_region(buf, motion, current.capture)
  if current.state == "repeat" then
    -- Reuse the operator's own last command, without prompting.
    if repeat_cmd then
      require("bang").run(repeat_cmd, region, { buf = buf, expanded = true })
    end
    return
  end
  prompt(buf, region, current.capture.visual)
end

---The range text of a command line: what is left of the command name once the
---modifiers are gone. A range never starts with a letter, so a leading word can
---only be a modifier -- and a modifier is not a range (F6).
---@param prefix string
---@return string
local function range_text(prefix)
  local rest = prefix:gsub("^%s*:*%s*", "")
  while rest:match("^%a") do
    rest = rest:gsub("^%a+!?%s*:*%s*", "")
  end
  return rest
end

---Whether the `:` history holds this very invocation, and if so whether the
---user typed the plain Visual range. Returns nil when the entry belongs to
---something else -- a mapping, `<Cmd>`, `vim.cmd`, or an empty history (R2).
---@param opts table Callback argument of the user command.
---@return boolean|nil
local function typed_visual_range(opts)
  local entry = fn.histget(":", -1)
  local name = entry ~= "" and entry:find("Bang", 1, true)
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
  return range_text(entry:sub(1, name - 1)):match("^'<%s*,%s*'>%s*$") ~= nil
end

---Whether the last blockwise selection in `buf` was made with `$`. While the
---selection is still live -- `i_CTRL-O`, or a `:Bang` from a mapping -- the
---cursor still knows; otherwise the recorded answer is the only one left (F4).
---@param buf integer
---@return boolean
---The blockwise geometry for a `:Bang` on `buf`. Read live when the selection is
---still current (`i_CTRL-O`, or a mapping firing mid-block); otherwise the
---geometry `CursorMoved` recorded while it was live. When neither is available
----- a block built in `:normal!`, where `CursorMoved` never fires -- the marks
---give the corners and the record supplies only the `$` flag (D-2, F4).
---@param buf integer
---@return bang.BlockGeometry
local function block_geometry(buf)
  if fn.mode() == regions.BLOCK then
    return live_block()
  end
  local record = block_record ~= nil and block_record.buf == buf and block_record or nil
  if record and record.anchor then
    return { anchor = record.anchor, cursor = record.cursor, ragged = record.ragged }
  end
  local geometry = block_from_marks()
  geometry.ragged = record ~= nil and record.ragged or false
  return geometry
end

---The region a `:Bang` call acts on (D3.3, R2). The last Visual selection is
---used only when the range covers exactly its lines, the selection was charwise
---or blockwise, and a typed command line does not say otherwise.
---@param opts table Callback argument of the user command.
---@param buf integer
---@return bang.Region region, boolean visual
local function command_region(opts, buf)
  local mode = fn.visualmode()
  local visual = opts.range == 2
    and opts.line1 == fn.line("'<")
    and opts.line2 == fn.line("'>")
    and (mode == "v" or mode == regions.BLOCK)
  if visual then
    local typed = typed_visual_range(opts)
    if typed ~= nil then
      visual = typed
    end
  end

  if visual then
    if mode == regions.BLOCK then
      -- The corners come from the live/recorded geometry, not `'<`/`'>` (D-2).
      return block_region(block_geometry(buf)), true
    end
    -- `coladd` (the 4th element) is where a 'virtualedit' selection keeps the
    -- part of its column that is past the end of the line (F7).
    local from, to = fn.getpos("'<"), fn.getpos("'>")
    return {
      type = mode,
      start = { lnum = from[2], col = from[3] + from[4] },
      finish = { lnum = to[2], col = to[3] + to[4] },
    },
      true
  end

  return {
    type = "V",
    start = { lnum = opts.line1, col = 1 },
    finish = { lnum = opts.line2, col = 1 },
  },
    false
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

---Create or remove the default `g!` / `g!!` keymaps. A key already mapped by
---the user is left alone, and only a mapping that is still ours is removed (R7).
---@param enable boolean
function M.default_keymaps(enable)
  for _, map in ipairs(DEFAULT_KEYMAPS) do
    for _, mode in ipairs(map.modes) do
      local existing = global_map(mode, map.lhs)
      if enable then
        if not existing then
          vim.keymap.set(mode, map.lhs, map.rhs, {
            remap = true,
            desc = "Filter through a shell command",
          })
        end
      elseif existing and existing.rhs == map.rhs then
        pcall(vim.keymap.del, mode, map.lhs)
      end
    end
  end
end

---Autocommands that watch what the keyboard is doing: what a blockwise Visual
---selection looks like while it is live (R1), and when an operator was
---abandoned so that `.` does not turn into a prompt (R3).
function M.setup_autocmds()
  local group = api.nvim_create_augroup("bang", { clear = true })
  api.nvim_create_autocmd("ModeChanged", {
    group = group,
    -- Entering starts a fresh record with no corners yet. `CursorMoved` fills
    -- them in as the block grows; a `:normal!` block never moves the cursor
    -- through the event loop, so its corners stay nil and the marks supply them.
    pattern = "*:" .. regions.BLOCK,
    callback = function()
      block_record = { buf = api.nvim_get_current_buf(), ragged = false }
    end,
  })
  api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function()
      -- Both corners are readable only while the block is live: `getpos("v")`
      -- is the anchor here, but collapses onto the cursor once the block ends.
      if fn.mode() == regions.BLOCK then
        block_record = vim.tbl_extend("error", { buf = api.nvim_get_current_buf() }, live_block())
      end
    end,
  })
  api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = regions.BLOCK .. ":*",
    callback = function()
      -- Leaving only ever adds `$`: curswant survives the `<Esc>` that ends a
      -- `:normal!` block, where `CursorMoved` never fired (F4). The anchor is
      -- gone by now, so only the flag is recorded; the marks give the corners.
      if block_record ~= nil and fn.getcurpos()[5] == vim.v.maxcol then
        block_record.ragged = true
      end
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
