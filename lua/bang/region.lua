-- Regions: the buffer half of the pipeline.
--
-- A region as the caller states it (line numbers and byte columns) is turned
-- into one segment per line, in the `getregionpos()` vocabulary. Everything
-- downstream -- the text handed to the command, the tab check, the write-back
-- and the marks -- is derived from those segments, so input and output can
-- never disagree about where the region is.

local api = vim.api
local fn = vim.fn

local M = {}

---Blockwise region type, i.e. CTRL-V.
M.BLOCK = "\22"

---@class bang.Segment
---@field lnum integer 1-based line number.
---@field scol integer 1-based first byte of the segment, 0 when the line holds no text of the region.
---@field ecol integer 1-based last byte of the segment (inclusive), 0 when there is none.

---@class bang.Block
---@field left integer Left edge of the block, in screen cells.
---@field width integer Width of the block, in screen cells.
---@field ragged boolean Whether the block was selected with `$`.

---@class bang.Resolved
---@field kind "char"|"line"|"block"
---@field segments bang.Segment[] One entry per line, top to bottom.
---@field block bang.Block|nil Present exactly when `kind` is "block".

local KINDS = { v = "char", V = "line", [M.BLOCK] = "block" }

---@param buf integer
---@param lnum integer
---@return string
local function get_line(buf, lnum)
  return api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
end

---`s` as a Vimscript function must be handed it. Inside a Vim string a buffer
---NUL is carried as a NL (`:help NL-used-for-Nul`): that is what `getline()`
---returns for one, `setbufline()` stores it back as a NUL, and
---`strdisplaywidth()` renders it under 'display' as the screen does. The NUL
---itself would make the Lua string a Blob, which those functions refuse, or
---write as the literal text `0z610062` (#23).
---@param s string
---@return string
local function as_vim_string(s)
  if not s:find("\0", 1, true) then
    return s
  end
  local carried = s:gsub("%z", "\n")
  return carried
end

---Screen cells `text` occupies when it starts at cell `start` (0-based).
---@param text string
---@param start integer|nil
---@return integer
local function display_width(text, start)
  return fn.strdisplaywidth(as_vim_string(text), start)
end

---First and last screen cell occupied by the byte at `col`.
---A column past the end of the line counts one cell per byte beyond it, so a
---caller can name a column that a short line does not reach.
---@param line string
---@param col integer 1-based byte column.
---@return integer first, integer last
local function cell_span(line, col)
  if col < 1 then
    return 1, 1
  end
  if col > #line then
    local cell = display_width(line) + (col - #line)
    return cell, cell
  end
  local before = display_width(line:sub(1, col - 1))
  local char = line:sub(col):match("^[%z\1-\127\194-\244][\128-\191]*") or line:sub(col, col)
  -- A <Tab> is as wide as the distance to the next tab stop, so its width is
  -- only defined relative to where it starts.
  return before + 1, before + display_width(char, before)
end

---The bytes of `line` whose screen cells overlap the block columns
---`[left, right]`. A <Tab> or a wide character on a boundary is included whole,
---exactly as Vim's own blockwise operators do -- `scol`/`ecol` snap to
---whole-character bounds -- so a boundary inside a <Tab> is no longer a refusal
---(D-2, superseding D5.5).
---@param line string
---@param left integer
---@param right integer
---@return integer scol, integer ecol
local function byte_range(line, left, right)
  local scol, ecol = 0, 0
  local byte, first = 1, 1
  while byte <= #line do
    local char = line:sub(byte):match("^[%z\1-\127\194-\244][\128-\191]*") or line:sub(byte, byte)
    local last = first + display_width(char, first - 1) - 1
    if last >= left and first <= right then
      if scol == 0 then
        scol = byte
      end
      ecol = byte + #char - 1
    end
    first = last + 1
    byte = byte + #char
  end
  return scol, ecol
end

---A byte column `getregionpos()` accepts on that line: past the last byte it
---raises E964, and a column of 0 only exists on an empty line.
---@param line string
---@param col integer
---@return integer
local function clamp_col(line, col)
  return math.max(1, math.min(col, math.max(#line, 1)))
end

---@param pos any
---@param what string
---@return { lnum: integer, col: integer }|nil, string|nil
local function normalize_pos(pos, what)
  if type(pos) ~= "table" then
    return nil, ("bang: region.%s must be a table, got %s"):format(what, type(pos))
  end
  local lnum, col = pos.lnum or pos[1], pos.col or pos[2]
  if type(lnum) ~= "number" or type(col) ~= "number" then
    return nil, ("bang: region.%s needs a line number and a byte column"):format(what)
  end
  return { lnum = math.floor(lnum), col = math.floor(col) }
end

---Check a caller-supplied region and put its two ends in buffer order.
---@param region table
---@return { kind: string, start: { lnum: integer, col: integer }, finish: { lnum: integer, col: integer } }|nil, string|nil
function M.normalize(region)
  if type(region) ~= "table" then
    return nil, ("bang: region must be a table, got %s"):format(type(region))
  end
  local kind = KINDS[region.type]
  if not kind then
    return nil,
      ('bang: region.type must be "v", "V" or CTRL-V, got %s'):format(vim.inspect(region.type))
  end
  local start, err = normalize_pos(region.start, "start")
  if not start then
    return nil, err
  end
  local finish, ferr = normalize_pos(region.finish, "finish")
  if not finish then
    return nil, ferr
  end
  if start.lnum > finish.lnum or (start.lnum == finish.lnum and start.col > finish.col) then
    start, finish = finish, start
  end
  if start.lnum < 1 then
    return nil, "bang: region is outside the buffer"
  end
  -- A block may carry its two live corners, which name the screen columns
  -- exactly; `'<`/`'>` cannot, once they are reordered by position (D-2).
  return { kind = kind, start = start, finish = finish, block = region.block }
end

---@param pos1 integer[]
---@param pos2 integer[]
---@param rtype string Region type, with an explicit width for a block.
---@return bang.Segment[]|nil, string|nil
local function segments_between(pos1, pos2, rtype)
  local ok, raw = pcall(fn.getregionpos, pos1, pos2, { type = rtype, exclusive = false })
  if not ok then
    return nil, ("bang: cannot resolve the region (%s)"):format(raw)
  end
  local segments = {}
  for _, pair in ipairs(raw) do
    local from, to = pair[1], pair[2]
    -- A non-zero offset means the boundary sits inside a <Tab>: half a tab is
    -- not representable in bytes, so the region cannot be replaced (D5.5).
    if from[4] ~= 0 or to[4] ~= 0 then
      return nil,
        ("bang: region boundary falls inside a <Tab> on line %d, cannot filter it"):format(from[2])
    end
    segments[#segments + 1] = { lnum = from[2], scol = from[3], ecol = to[3] }
  end
  return segments
end

---@class bang.BlockHint How an adapter names a block's screen columns, which
---`'<`/`'>` cannot once they are reordered by position (D-2): both corners
---while the selection is live, or one corner plus the width a `.` replays.
---@field anchor { lnum: integer, col: integer } A corner: 1-based line, byte column plus coladd.
---@field cursor { lnum: integer, col: integer }|nil The other corner.
---@field width integer|nil Width in screen cells, in place of `cursor`.
---@field ragged boolean Whether `$` is active.

---@class bang.BlockShape
---@field width integer Width in screen cells.
---@field ragged boolean Whether `$` is active.

---Left and right screen cells of the block a hint describes.
---@param buf integer
---@param hint bang.BlockHint
---@return integer left, integer right
local function hint_columns(buf, hint)
  local a = hint.anchor
  local aleft, aright = cell_span(get_line(buf, a.lnum), a.col)
  if hint.width then
    -- A `.` replays a width that was measured through this function, so it is
    -- already whatever 'selection' made of the original block.
    return aleft, aleft + hint.width - 1
  end
  local c = hint.cursor
  local cleft, cright = cell_span(get_line(buf, c.lnum), c.col)
  -- Vim builds the block from the corner earlier in the buffer and the one
  -- later: the later corner widens the block to its own right edge, except
  -- that 'selection' = "exclusive" leaves that corner's character out when the
  -- block stays at least as wide as the earlier corner's character without it.
  -- So `l<C-v>ld` on "1234" gives "134", `<C-v>jh` still takes both columns,
  -- and a <Tab> or a wide character on the right edge stays in whole (#8).
  local later = c.lnum > a.lnum or (c.lnum == a.lnum and c.col > a.col)
  local eleft, eright, lleft, lright = aleft, aright, cleft, cright
  if not later then
    eleft, eright, lleft, lright = cleft, cright, aleft, aright
  end
  local right = eright
  if lright > eright then
    if vim.o.selection == "exclusive" and lleft - 1 >= eright then
      right = lleft - 1
    else
      right = lright
    end
  end
  return math.min(eleft, lleft), right
end

---The shape of the block a hint describes, for a `.` repeat to replay. Vim
---rebuilds the block at the cursor, but the opfunc can read back neither its
---width (`']` clamps to a short last line) nor `$` (curswant is a column again).
---@param buf integer
---@param hint bang.BlockHint
---@return bang.BlockShape
function M.block_shape(buf, hint)
  local left, right = hint_columns(buf, hint)
  return { width = right - left + 1, ragged = hint.ragged }
end

---@param buf integer
---@param region table Result of `M.normalize`.
---@return bang.Resolved|nil, string|nil
local function resolve_block(buf, region)
  local l1, l2 = region.start.lnum, region.finish.lnum
  local left, right, ragged
  if region.block then
    -- Each screen column stays with its own corner. A far corner on a short
    -- line, or a `$` corner, no longer drags the edge (D-2).
    left, right = hint_columns(buf, region.block)
    ragged = region.block.ragged
  else
    -- Raw `run()` with byte columns: the marks are all there is. Both edges come
    -- from the columns as given, never from clamped ones (R5, F7).
    local sleft, sright = cell_span(get_line(buf, l1), region.start.col)
    local fleft, fright = cell_span(get_line(buf, l2), region.finish.col)
    ragged = region.start.col == vim.v.maxcol or region.finish.col == vim.v.maxcol
    -- A maxcol corner means "to end of line", not a real column, so it must not
    -- pull the left edge out to infinity.
    left = ragged and (region.start.col == vim.v.maxcol and fleft or sleft)
      or math.min(sleft, fleft)
    right = math.max(sright, fright)
  end
  local longest = 0
  for lnum = l1, l2 do
    longest = math.max(longest, display_width(get_line(buf, lnum)))
  end
  -- The last cell of the longest line is as far as a block can reach usefully;
  -- past it only padding follows, which the write-back trims off again. This is
  -- what keeps a `$` block from asking for a million spaces.
  local reach = math.max(longest, left)
  local edge = ragged and reach or math.min(right, reach)
  local block = { left = left, width = math.max(1, edge - left + 1), ragged = ragged }

  -- Segments come straight from the block's own screen columns. Asking
  -- `getregionpos()` would re-derive the left edge from clamped positions and
  -- drop `off`, sliding the whole block left on a short first or last line (F2).
  local segments = {}
  for lnum = l1, l2 do
    local scol, ecol = byte_range(get_line(buf, lnum), left, edge)
    segments[#segments + 1] = { lnum = lnum, scol = scol, ecol = ecol }
  end
  return { kind = "block", segments = segments, block = block }
end

---Turn a normalized region into one segment per line.
---@param buf integer
---@param region table Result of `M.normalize`.
---@return bang.Resolved|nil, string|nil
function M.resolve(buf, region)
  local last_line = api.nvim_buf_line_count(buf)
  if region.start.lnum > last_line or region.finish.lnum > last_line then
    return nil, "bang: region is outside the buffer"
  end
  local l1, l2 = region.start.lnum, region.finish.lnum

  if region.kind == "line" then
    local segments = {}
    for lnum = l1, l2 do
      segments[#segments + 1] = { lnum = lnum, scol = 1, ecol = #get_line(buf, lnum) }
    end
    return { kind = "line", segments = segments }
  end

  if region.kind == "block" then
    return resolve_block(buf, region)
  end

  local pos1 = { buf, l1, clamp_col(get_line(buf, l1), region.start.col), 0 }
  local pos2 = { buf, l2, clamp_col(get_line(buf, l2), region.finish.col), 0 }
  local segments, err = segments_between(pos1, pos2, "v")
  if not segments then
    return nil, err
  end
  return { kind = "char", segments = segments }
end

---The screen cell (0-based) where a segment's text starts, which is where a
---<Tab> inside it begins counting: after the line's own text before the
---segment, or at the block's left edge when the line stops short of it. Every
---width of a block row is measured from here, on the way in and on the way
---out, so a <Tab> is as wide in the write-back as it was in the input (#8).
---@param line string
---@param seg bang.Segment
---@param block bang.Block
---@return integer
local function segment_start(line, seg, block)
  if seg.scol == 0 then
    return block.left - 1
  end
  return display_width(line:sub(1, seg.scol - 1))
end

---The text the command receives, one string per line of the region.
---Rows of a block are padded to the block width so that a command which maps
---lines to lines sees the column it was pointed at, and so that sorting a
---ragged column cannot shift text that follows it (D5.4, R10).
---@param buf integer
---@param resolved bang.Resolved
---@return string[]
function M.text(buf, resolved)
  local out = {}
  for i, seg in ipairs(resolved.segments) do
    local line = get_line(buf, seg.lnum)
    local text = seg.scol == 0 and "" or line:sub(seg.scol, seg.ecol)
    if resolved.block then
      local start = segment_start(line, seg, resolved.block)
      local pad = resolved.block.width - display_width(text, start)
      if pad > 0 then
        text = text .. string.rep(" ", pad)
      end
    end
    out[i] = text
  end
  return out
end

---What goes on the command's stdin. Whole lines end with a newline, as `!`
---sends them; a charwise selection contains none, so none is added (D5.2).
---@param resolved bang.Resolved
---@param lines string[]
---@return string
function M.stdin(resolved, lines)
  local text = table.concat(lines, "\n")
  if resolved.kind ~= "char" then
    text = text .. "\n"
  end
  return text
end

---Split command output into buffer lines (D7.1). Zero-byte output yields no
---lines at all. A bare `\r` is not a line break here, unlike in the built-in
---filter (DEV-5).
---
---The trailing newline is dropped because the plugin's own line joining put it
---there -- unless the region's stdin already ended in one, which happens when a
---charwise selection ends on an empty line. Stripping it then would swallow
---that line and `cat` would not be an identity (F3).
---@param text string
---@param stdin_ended_with_newline boolean
---@return string[]
function M.output_lines(text, stdin_ended_with_newline)
  if text == "" then
    return {}
  end
  if not stdin_ended_with_newline and text:sub(-1) == "\n" then
    text = text:sub(1, -2)
  end
  return vim.split(text, "\n", { plain = true })
end

---@class bang.Written Both ends of the text a writer put in the buffer, as
---`'[` and `']` take them: a 1-based line and a 0-based byte column, which is
---also what the cursor takes. The writer is the only place that knows what it
---wrote and where, so it names both marks rather than leaving one to be
---re-derived from the region.
---@field from [integer, integer] Where the new text starts: `'[`, and the line the cursor lands on.
---@field to [integer, integer] Where it ends: `']`.

---@param buf integer
---@param resolved bang.Resolved
---@param lines string[]
---@return bang.Written
local function write_charwise(buf, resolved, lines)
  local first = resolved.segments[1]
  local last = resolved.segments[#resolved.segments]
  local scol = first.scol == 0 and 0 or first.scol - 1
  if #lines == 0 then
    lines = { "" }
  end
  api.nvim_buf_set_text(buf, first.lnum - 1, scol, last.lnum - 1, last.ecol, lines)
  -- Only a single output line still starts at the region's own column; any
  -- further line begins at column 0.
  local end_col = #lines[#lines] + (#lines == 1 and scol or 0)
  return {
    from = { first.lnum, scol },
    to = { first.lnum + #lines - 1, math.max(0, end_col - 1) },
  }
end

---The lines as a Vimscript function must be handed them; see `as_vim_string`.
---@param lines string[]
---@return string[]
local function as_vim_lines(lines)
  return vim.tbl_map(as_vim_string, lines)
end

---Replace lines `first..last` (1-based, inclusive) with `lines`, keeping marks
---the way the built-in filter does ('cpo-R'): a mark stays on its line while
---that line exists, marks below shift with the line count, and only marks on
---lines the output no longer has are deleted. `nvim_buf_set_lines` would drop
---every mark in the range and pull `'<`/`'>` to its first line, and on 0.11
---`nvim_buf_set_text` drops the mark on a line it rewrites whole.
---@param buf integer
---@param first integer
---@param last integer
---@param lines string[]
local function replace_lines(buf, first, last, lines)
  local old, new = last - first + 1, #lines
  local kept = math.min(old, new)
  local vlines = as_vim_lines(lines)
  -- These three raise on a nomodifiable buffer (E21) instead of reporting; what
  -- they report with a non-zero return is a line number outside the buffer or
  -- an invalid buffer handle, neither of which reaches here. The checks stay: a
  -- write that silently does nothing while the run reports success is the
  -- shape bug #23 had.
  local failed = kept > 0 and fn.setbufline(buf, first, vim.list_slice(vlines, 1, kept)) ~= 0
  if not failed and new > old then
    failed = fn.appendbufline(buf, last, vim.list_slice(vlines, kept + 1)) ~= 0
  elseif not failed and new < old then
    failed = fn.deletebufline(buf, first + kept, last) ~= 0
  end
  if failed then
    error(("could not replace lines %d-%d"):format(first, last), 0)
  end
end

---@param buf integer
---@param resolved bang.Resolved
---@param lines string[]
---@return bang.Written
local function write_linewise(buf, resolved, lines)
  local first = resolved.segments[1].lnum
  local last = resolved.segments[#resolved.segments].lnum
  replace_lines(buf, first, last, lines)
  -- Output shorter than the region leaves the buffer with fewer lines than the
  -- region had, and a mark can only sit on a line that still exists.
  local count = api.nvim_buf_line_count(buf)
  return {
    from = { math.min(first, count), 0 },
    to = { math.min(first + math.max(#lines, 1) - 1, count), 0 },
  }
end

---@param buf integer
---@param resolved bang.Resolved
---@param lines string[] As many lines as the block has, checked by the caller.
---@return bang.Written
local function write_blockwise(buf, resolved, lines)
  local segments, block = resolved.segments, resolved.block
  -- Rows of unequal width are padded so that the text to the right of the
  -- block moves by the same amount on every line, which is what blockwise put
  -- does with a register of uneven rows. The measure is each row's growth
  -- against what the command was handed for it -- the block's width, or more
  -- where a <Tab> or a wide character joined the block whole -- so a command
  -- that keeps every row's width, `gU` included, pads nothing, and a block
  -- cleared to nothing pads nothing either (#8).
  local rows, most = {}, -math.huge
  for i, seg in ipairs(segments) do
    local line = get_line(buf, seg.lnum)
    local original = seg.scol == 0 and "" or line:sub(seg.scol, seg.ecol)
    local start = segment_start(line, seg, block)
    local had = display_width(original, start)
    local growth = display_width(lines[i], start) - math.max(block.width, had)
    rows[i] = { line = line, had = had, growth = growth }
    most = math.max(most, growth)
  end
  local rewritten, start_col, end_col = {}, 0, 0
  for i, seg in ipairs(segments) do
    local line = rows[i].line
    local align = most - rows[i].growth
    local text = lines[i] .. string.rep(" ", align)
    if seg.scol == 0 or seg.ecol >= #line then
      -- Where the block runs off the end of the line, take back the spaces the
      -- plugin added -- the input padding and the alignment padding, exactly
      -- those, never the buffer's own (F8, R10, #8).
      local added = math.max(0, block.width - rows[i].had) + align
      local trailing = #(text:match(" *$") or "")
      text = text:sub(1, #text - math.min(added, trailing))
    end
    local head, tail = line, ""
    if seg.scol ~= 0 then
      head, tail = line:sub(1, seg.scol - 1), line:sub(seg.ecol + 1)
    elseif text ~= "" then
      -- The line stops before the block. Pad it out to the block column and put
      -- the output there, the way blockwise insert does (D5.4). With nothing to
      -- put there the line keeps its own text, and the head is all of it.
      head = line .. string.rep(" ", math.max(0, block.left - 1 - display_width(line)))
    end
    rewritten[i] = head .. text .. tail
    if i == 1 then
      -- `'[` goes where the new text starts, so on a line that stops before the
      -- block it goes past the line's own last byte, as `gU` leaves it (D7.5).
      start_col = #head
    end
    if i == #segments then
      -- `'[` and `']` bracket the bytes the run wrote, as `:help ']` has it, so
      -- `']` goes on the last byte of the new text. A row that received nothing
      -- -- one the block never reached, or one the command cleared -- has no
      -- such byte, and the mark goes where the block ends on that row instead:
      -- the character after a cleared block, and past the row's own end where
      -- the block reaches beyond it, both of which is where blockwise `d` puts
      -- it (#8, #25).
      end_col = #head + math.max(#text, 1) - 1
    end
  end
  -- One write for the whole block, and every row is built before it, so a
  -- failure while building leaves the buffer untouched (F9, D7.6). Inside that
  -- one call Neovim still reports each line to a buffer-attach callback, and a
  -- change made from one of those is not guarded (#28).
  replace_lines(buf, segments[1].lnum, segments[#segments].lnum, rewritten)
  return {
    from = { segments[1].lnum, start_col },
    to = { segments[#segments].lnum, end_col },
  }
end

---Replace the region with `lines`, then set `'[`, `']` and the cursor (D7.5).
---Refuses without touching the buffer when a blockwise output does not line up,
---and reports rather than raises when the buffer rejects the write (R8).
---@param buf integer
---@param resolved bang.Resolved
---@param lines string[]
---@return string|nil error
function M.write(buf, resolved, lines)
  if not resolved.segments[1] then
    return nil
  end
  if resolved.kind == "block" and #lines ~= #resolved.segments then
    if #lines > 0 then
      -- No non-arbitrary way to map a different number of lines onto the block,
      -- so refuse before the first write (D7.4).
      return ("bang: the command returned %d line(s) for a %d-line block, nothing was replaced"):format(
        #lines,
        #resolved.segments
      )
    end
    -- Zero output clears the block instead: every row becomes empty and the
    -- text after it moves left, as blockwise `d` does (#8).
    lines = {}
    for _ = 1, #resolved.segments do
      lines[#lines + 1] = ""
    end
  end

  -- Every write below saves undo state first, which is where Neovim itself
  -- fires FileChangedRO and warns W10 on the first change to a readonly
  -- buffer, exactly as the built-in filter does (#8).
  local ok, result = pcall(function()
    if resolved.kind == "line" then
      return write_linewise(buf, resolved, lines)
    elseif resolved.kind == "block" then
      return write_blockwise(buf, resolved, lines)
    end
    return write_charwise(buf, resolved, lines)
  end)
  if not ok then
    local message = tostring(result)
    if message:find("not 'modifiable'", 1, true) then
      -- Only the API words it this way; `setbufline()` raises E21 and falls
      -- through below. `run()` refused a nomodifiable buffer before the write,
      -- so reaching this takes 'modifiable' going off during the one charwise
      -- call, which no probe has managed. A guard, and one that claims nothing
      -- about how much of the region was replaced (#28).
      return "bang: buffer is not modifiable"
    end
    -- Anything else is a bug: keep the location it came with (F9).
    return ("bang: %s"):format(message)
  end

  api.nvim_buf_set_mark(buf, "[", result.from[1], result.from[2], {})
  api.nvim_buf_set_mark(buf, "]", result.to[1], result.to[2], {})
  if api.nvim_get_current_buf() == buf then
    local lnum, col = result.from[1], result.from[2]
    local line = get_line(buf, lnum)
    if resolved.kind == "line" then
      -- Linewise, `!` leaves the cursor on the first non-blank of the new text;
      -- on an all-blank line it stops at the last character (D7.5).
      col = math.max(0, (line:find("[^ \t]") or #line) - 1)
    end
    -- A mark may sit past the last byte of its line, a cursor may not.
    api.nvim_win_set_cursor(0, { lnum, math.min(col, math.max(#line - 1, 0)) })
  end
  return nil
end

return M
