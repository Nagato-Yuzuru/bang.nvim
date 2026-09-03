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
    local cell = fn.strdisplaywidth(line) + (col - #line)
    return cell, cell
  end
  local before = fn.strdisplaywidth(line:sub(1, col - 1))
  local char = line:sub(col):match("^[%z\1-\127\194-\244][\128-\191]*") or line:sub(col, col)
  -- A <Tab> is as wide as the distance to the next tab stop, so its width is
  -- only defined relative to where it starts.
  return before + 1, before + fn.strdisplaywidth(char, before)
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
    local last = first + fn.strdisplaywidth(char, first - 1) - 1
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

---@param buf integer
---@param region table Result of `M.normalize`.
---@return bang.Resolved|nil, string|nil
local function resolve_block(buf, region)
  local l1, l2 = region.start.lnum, region.finish.lnum
  local left, right, ragged
  if region.block then
    -- The two live corners keep each screen column with its own corner. A far
    -- corner on a short line, or a `$` corner, no longer drags the edge (D-2).
    local a, c = region.block.anchor, region.block.cursor
    local aleft, aright = cell_span(get_line(buf, a.lnum), a.col)
    local cleft, cright = cell_span(get_line(buf, c.lnum), c.col)
    left, right, ragged = math.min(aleft, cleft), math.max(aright, cright), region.block.ragged
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
    longest = math.max(longest, fn.strdisplaywidth(get_line(buf, lnum)))
  end
  -- The last cell of the longest line is as far as a block can reach usefully;
  -- past it only padding follows, which the write-back trims off again. This is
  -- what keeps a `$` block from asking for a million spaces.
  local reach = math.max(longest, left)
  right = ragged and reach or math.min(right, reach)
  local block = { left = left, width = math.max(1, right - left + 1), ragged = ragged }

  -- Segments come straight from the block's own screen columns. Asking
  -- `getregionpos()` would re-derive the left edge from clamped positions and
  -- drop `off`, sliding the whole block left on a short first or last line (F2).
  local segments = {}
  for lnum = l1, l2 do
    local scol, ecol = byte_range(get_line(buf, lnum), left, right)
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
    local text = seg.scol == 0 and "" or get_line(buf, seg.lnum):sub(seg.scol, seg.ecol)
    if resolved.block then
      local pad = resolved.block.width - fn.strdisplaywidth(text)
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

---@param buf integer
---@param resolved bang.Resolved
---@param lines string[]
---@return integer lnum, integer col 0-based end of the text just written.
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
  local end_lnum = first.lnum - 1 + #lines - 1
  local end_col = #lines[#lines] + (#lines == 1 and scol or 0)
  return end_lnum, math.max(0, end_col - 1)
end

---@param buf integer
---@param resolved bang.Resolved
---@param lines string[]
---@return integer lnum, integer col
local function write_linewise(buf, resolved, lines)
  local first = resolved.segments[1].lnum - 1
  local last = resolved.segments[#resolved.segments].lnum
  api.nvim_buf_set_lines(buf, first, last, false, lines)
  return math.max(0, first + math.max(#lines, 1) - 1), 0
end

---@param buf integer
---@param resolved bang.Resolved
---@param lines string[] As many lines as the block has, checked by the caller.
---@return integer lnum, integer col
local function write_blockwise(buf, resolved, lines)
  local segments, block = resolved.segments, resolved.block
  local rewritten, end_col = {}, 0
  for i, seg in ipairs(segments) do
    local line = get_line(buf, seg.lnum)
    local original = seg.scol == 0 and "" or line:sub(seg.scol, seg.ecol)
    local text = lines[i]
    if seg.scol == 0 or seg.ecol >= #line then
      -- Where the block runs off the end of the line, take back the spaces the
      -- padding added -- exactly those, never the buffer's own (F8, R10).
      local added = math.max(0, block.width - fn.strdisplaywidth(original))
      local trailing = #(text:match(" *$") or "")
      text = text:sub(1, #text - math.min(added, trailing))
    end
    if seg.scol == 0 and text == "" then
      rewritten[i] = line
    else
      local head, tail
      if seg.scol == 0 then
        -- The line stops before the block. Pad it out to the block column and
        -- put the output there, the way blockwise insert does (D5.4).
        local pad = math.max(0, block.left - 1 - fn.strdisplaywidth(line))
        head, tail = line .. string.rep(" ", pad), ""
      else
        head, tail = line:sub(1, seg.scol - 1), line:sub(seg.ecol + 1)
      end
      rewritten[i] = head .. text .. tail
      if i == #segments then
        end_col = #head + #text
      end
    end
  end
  -- One write for the whole block: a failure part way through the rows must not
  -- leave the buffer half filtered (F9, D7.6).
  api.nvim_buf_set_lines(buf, segments[1].lnum - 1, segments[#segments].lnum, false, rewritten)
  return segments[#segments].lnum - 1, math.max(0, end_col - 1)
end

---Replace the region with `lines`, then set `'[`, `']` and the cursor (D7.5).
---Refuses without touching the buffer when a blockwise output does not line up,
---and reports rather than raises when the buffer rejects the write (R8).
---@param buf integer
---@param resolved bang.Resolved
---@param lines string[]
---@return string|nil error
function M.write(buf, resolved, lines)
  local start = resolved.segments[1]
  if not start then
    return nil
  end
  if resolved.kind == "block" and #lines ~= #resolved.segments then
    -- No non-arbitrary way to map a different number of lines onto the block,
    -- so refuse before the first write (D7.4).
    return ("bang: the command returned %d line(s) for a %d-line block, nothing was replaced"):format(
      #lines,
      #resolved.segments
    )
  end

  local ok, result = pcall(function()
    local lnum, col
    if resolved.kind == "line" then
      lnum, col = write_linewise(buf, resolved, lines)
    elseif resolved.kind == "block" then
      lnum, col = write_blockwise(buf, resolved, lines)
    else
      lnum, col = write_charwise(buf, resolved, lines)
    end
    return { lnum = lnum, col = col }
  end)
  if not ok then
    local message = tostring(result)
    if message:find("not 'modifiable'", 1, true) then
      return "bang: buffer is not modifiable, nothing was replaced"
    end
    -- Anything else is a bug: keep the location it came with (F9).
    return ("bang: %s"):format(message)
  end

  local start_col = resolved.kind == "line" and 0 or math.max(0, start.scol - 1)
  local line_count = api.nvim_buf_line_count(buf)
  local start_lnum = math.min(start.lnum, line_count)
  local end_lnum = math.max(0, math.min(result.lnum, line_count - 1))
  api.nvim_buf_set_mark(buf, "[", start_lnum, start_col, {})
  api.nvim_buf_set_mark(buf, "]", end_lnum + 1, result.col, {})
  if api.nvim_get_current_buf() == buf then
    local line = get_line(buf, start_lnum)
    local col = start_col
    if resolved.kind == "line" then
      -- Linewise, `!` leaves the cursor on the first non-blank of the new text;
      -- on an all-blank line it stops at the last character (D7.5).
      col = math.max(0, (line:find("[^ \t]") or #line) - 1)
    end
    api.nvim_win_set_cursor(0, { start_lnum, math.min(col, math.max(#line - 1, 0)) })
  end
  return nil
end

return M
