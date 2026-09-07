-- Regions: the buffer half of the pipeline.
--
-- A region as the caller states it (two `getpos()` positions) is turned into one
-- segment per line by `getregionpos()`, which owns the geometry of all three
-- kinds. Everything downstream -- the text handed to the command, the tab check,
-- the write-back and the marks -- is derived from those segments, so input and
-- output can never disagree about where the region is.

local api = vim.api
local fn = vim.fn

local M = {}

---Blockwise region type, i.e. CTRL-V.
M.BLOCK = "\22"

---@class bang.Segment
---@field lnum integer 1-based line number.
---@field scol integer 1-based first byte of the segment, 0 when a block never reaches the line.
---@field ecol integer 1-based last byte of the segment (inclusive), 0 when there is none.
---A charwise segment always names real byte columns: a line the region holds no
---text of is the empty span after its last byte, `scol = #line + 1`, `ecol = #line`.

---@class bang.Block
---@field left integer Left edge of the block, in screen cells.
---@field width integer Width of the block, in screen cells.
---@field ragged boolean Whether the block was selected with `$`.

---@class bang.Resolved
---@field kind "char"|"line"|"block"
---@field segments bang.Segment[] One entry per line, top to bottom.
---@field block bang.Block|nil Present exactly when `kind` is "block".

local KINDS = { char = true, line = true, block = true }

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

---The bytes of the character that starts at `col`.
---@param line string
---@param col integer
---@return integer
local function char_bytes(line, col)
  local char = line:sub(col):match("^[%z\1-\127\194-\244][\128-\191]*")
  return char and #char or 1
end

---Whether `n` is a number a position may be built from. NaN and infinity pass
---`type()` and reach `getregionpos()` as "not integral", which raises where the
---contract promises a report; a fraction of a byte column means nothing either.
---@param n any
---@return boolean
local function is_index(n)
  return type(n) == "number" and n == math.floor(n) and n > -math.huge and n < math.huge
end

---@param pos any
---@param what string
---@return { lnum: integer, col: integer, off: integer }|nil, string|nil
local function normalize_pos(pos, what)
  if type(pos) ~= "table" then
    return nil, ("bang: region.%s must be a table, got %s"):format(what, type(pos))
  end
  local off = pos.off == nil and 0 or pos.off
  if not is_index(pos.lnum) or not is_index(pos.col) then
    return nil, ("bang: region.%s needs a whole line number and byte column"):format(what)
  end
  -- Virtual space only ever runs to the right of the byte: a negative offset
  -- would pull the region's edge left of the column it was given and, for a
  -- block, pad the rows out with spaces on the way back.
  if not is_index(off) or off < 0 then
    return nil, ("bang: region.%s.off must be a whole number of cells, 0 or more"):format(what)
  end
  return { lnum = pos.lnum, col = pos.col, off = off }
end

---Check a caller-supplied region and put its two ends in buffer order. Which of
---them is the anchor and which the cursor matters only to `getregionpos()`, and
---it reads the pair either way round.
---@param region table
---@return { kind: string, anchor: table, cursor: table, ragged: boolean }|nil, string|nil
function M.normalize(region)
  if type(region) ~= "table" then
    return nil, ("bang: region must be a table, got %s"):format(type(region))
  end
  if not KINDS[region.kind] then
    return nil,
      ('bang: region.kind must be "char", "line" or "block", got %s'):format(
        vim.inspect(region.kind)
      )
  end
  if region.ragged ~= nil and type(region.ragged) ~= "boolean" then
    return nil, ("bang: region.ragged must be a boolean, got %s"):format(type(region.ragged))
  end
  if region.exclusive ~= nil and type(region.exclusive) ~= "boolean" then
    return nil, ("bang: region.exclusive must be a boolean, got %s"):format(type(region.exclusive))
  end
  if region.width ~= nil then
    if region.kind ~= "block" then
      return nil, ("bang: region.width is blockwise only, got kind %q"):format(region.kind)
    end
    -- Bounded because it reaches `getregionpos()` as part of the region type:
    -- a number too big to be a column is not a block anyone drew, and `v:maxcol`
    -- is where Vim itself stops counting them.
    if not is_index(region.width) or region.width < 1 or region.width > vim.v.maxcol then
      return nil,
        ("bang: region.width must be a whole number of cells, 1 to %d, got %s"):format(
          vim.v.maxcol,
          vim.inspect(region.width)
        )
    end
    -- A width says where the block's right edge is; "exclusive" says the cursor
    -- end decides it. Only one of them can be right.
    if region.exclusive then
      return nil, "bang: region.width and region.exclusive contradict each other"
    end
  end
  local anchor, aerr = normalize_pos(region.anchor, "anchor")
  if not anchor then
    return nil, aerr
  end
  local cursor, cerr = normalize_pos(region.cursor, "cursor")
  if not cursor then
    return nil, cerr
  end
  -- Two corners describe the same region either way round, and
  -- `getregionpos()` reads them either way round, so they go in buffer order
  -- and nothing downstream has to ask again. A `width` region is not a pair of
  -- corners: its anchor is where the block starts and has to stay there.
  local swap = anchor.lnum > cursor.lnum or (anchor.lnum == cursor.lnum and anchor.col > cursor.col)
  if swap and not region.width then
    anchor, cursor = cursor, anchor
  end
  if math.min(anchor.lnum, cursor.lnum) < 1 then
    return nil, "bang: region is outside the buffer"
  end
  return {
    kind = region.kind,
    anchor = anchor,
    cursor = cursor,
    ragged = region.ragged == true,
    exclusive = region.exclusive == true,
    width = region.width,
  }
end

---A position as `getregionpos()` takes it. It raises E964 on a column the line
---does not have, so everything past the last byte plus one becomes virtual
---space instead -- the cells a block may stand in past the end of a line (R5).
---And a position names a character, not a byte inside one: a byte column inside
---a multibyte character would cut the region there and hand the command half a
---character, which is not text -- and a prefix that ends mid-character is not a
---width to measure a corner by either.
---@param buf integer
---@param pos { lnum: integer, col: integer, off: integer }
---@return integer[] position, string line
local function corner(buf, pos)
  local line = get_line(buf, pos.lnum)
  local col = math.min(pos.col, #line + 1)
  local off = pos.off + math.max(0, pos.col - col)
  col = math.max(1, col)
  if col <= #line then
    col = col + vim.str_utf_start(line, col)
  end
  return { buf, pos.lnum, col, off }, line
end

---The screen cell a corner stands on: the first cell of the character at its
---column, plus its cells of virtual space.
---@param line string
---@param pos integer[]
---@return integer
local function corner_cell(line, pos)
  return display_width(line:sub(1, pos[3] - 1)) + 1 + pos[4]
end

---The last screen cell of the character a corner sits on. A block takes that
---character whole -- a <Tab> or a wide one included -- which is how Vim's own
---blockwise operators treat a corner (D-2). A corner in virtual space sits on
---no character, and neither does one past the line's last byte: both cover the
---single cell they stand on.
---@param line string
---@param pos integer[]
---@return integer
local function corner_char_end(line, pos)
  local cell = corner_cell(line, pos)
  if pos[4] ~= 0 or pos[3] > #line then
    return cell
  end
  local char = line:sub(pos[3], pos[3] + char_bytes(line, pos[3]) - 1)
  return math.max(cell, cell - 1 + display_width(char, cell - 1))
end

---`getregionpos()` on a pair of positions, reported rather than raised.
---
---Virtual space -- a non-zero `off` -- only exists for Vim while 'virtualedit'
---allows a position there, and it is dropped otherwise, sliding the region onto
---the last real column. The option is turned on for the call so that a region
---stands where the caller put it whatever the user's own setting (R5, F7). Only
---the window's own value is touched: 'virtualedit' is global-local, and `vim.o`
---would write the global one too, promoting a `:setlocal` value to every window
---opened afterwards.
---@param pos1 integer[]
---@param pos2 integer[]
---@param rtype string
---@param exclusive boolean Whether the cursor end's character is left out.
---@return table[]|nil, string|nil
local function region_pairs(pos1, pos2, rtype, exclusive)
  local scope = { scope = "local", win = 0 }
  local saved = (pos1[4] ~= 0 or pos2[4] ~= 0) and api.nvim_get_option_value("virtualedit", scope)
    or nil
  if saved then
    api.nvim_set_option_value("virtualedit", "all", scope)
  end
  local ok, raw = pcall(fn.getregionpos, pos1, pos2, { type = rtype, exclusive = exclusive })
  if saved then
    api.nvim_set_option_value("virtualedit", saved, scope)
  end
  if not ok then
    return nil, ("bang: cannot resolve the region (%s)"):format(raw)
  end
  return raw
end

---@param buf integer
---@param region table Result of `M.normalize`.
---@return bang.Resolved|nil, string|nil
local function resolve_block(buf, region)
  local pos1, line1 = corner(buf, region.anchor)
  local pos2, rtype, left
  if region.width then
    -- Vim's own model of a repeated block: `width` cells from the anchor's own
    -- cell, with the cursor naming the last line and nothing else. A
    -- width-typed block starts at the leftmost of the two positions, so the
    -- second one is put at the anchor's cell on its own line -- in the virtual
    -- space past the end of a line too short to hold it -- where it can only
    -- ever tie, never drag the edge left.
    left = corner_cell(line1, pos1)
    local line2 = get_line(buf, region.cursor.lnum)
    pos2 = { buf, region.cursor.lnum, #line2 + 1, math.max(0, left - display_width(line2) - 1) }
    rtype = M.BLOCK .. ("%d"):format(region.width)
  else
    -- `getregionpos()` owns the geometry: 'selection', the cells a short line
    -- never reaches, and a <Tab> or a wide character a corner sits on, which
    -- widens the block to cover it whole (D-2). The left edge is the one thing
    -- it does not report -- a row the block does not reach has no bytes to
    -- report it with -- so that comes from the corners.
    local line2
    pos2, line2 = corner(buf, region.cursor)
    left = math.min(corner_cell(line1, pos1), corner_cell(line2, pos2))
    rtype = M.BLOCK
  end
  local raw, err = region_pairs(pos1, pos2, rtype, region.exclusive)
  if not raw then
    return nil, err
  end
  local segments, edge = {}, left
  for _, pair in ipairs(raw) do
    local from, to = pair[1], pair[2]
    local scol, ecol = from[3], 0
    if scol > 0 then
      local line = get_line(buf, from[2])
      ecol = to[3]
      local reach = display_width(line:sub(1, ecol))
      if to[4] ~= 0 then
        -- A non-zero offset means the right edge falls part-way into a <Tab> or
        -- a wide character, and counts the cells of it the block covers. The row
        -- takes that character whole, as Vim's own blockwise operators do, while
        -- the block's own edge stays where it was (D-2, superseding D5.5).
        reach = display_width(line:sub(1, ecol - 1)) + to[4]
        ecol = ecol + char_bytes(line, ecol) - 1
      end
      -- `$` is the one fact two positions cannot carry: the right edge is then
      -- every row's own end.
      if region.ragged then
        ecol, reach = #line, display_width(line)
      end
      -- The last cell any row of the block reaches, which is as far as it can
      -- reach usefully: past that only padding follows, which the write-back
      -- trims off again. It is what keeps a `$` block from asking for a million
      -- spaces.
      edge = math.max(edge, reach)
    end
    segments[#segments + 1] = { lnum = from[2], scol = scol, ecol = ecol }
  end
  return {
    kind = "block",
    segments = segments,
    block = { left = left, width = math.max(1, edge - left + 1), ragged = region.ragged },
  }
end

---@param buf integer
---@param region table Result of `M.normalize`.
---@return bang.Resolved|nil, string|nil
local function resolve_char(buf, region)
  local pos1 = corner(buf, region.anchor)
  local pos2 = corner(buf, region.cursor)
  local raw, err = region_pairs(pos1, pos2, "v", region.exclusive)
  if not raw then
    return nil, err
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
    local scol, ecol = from[3], to[3]
    if scol == 0 then
      -- Column 0 is `getregionpos()` for "this line holds no text of the
      -- region": an empty line, or a first line the region starts past the end
      -- of. Written as the empty span after that line's last byte, because the
      -- write-back needs a byte column to start from and would read 0 as
      -- column 1 and swallow the line (#22).
      local line = get_line(buf, from[2])
      scol, ecol = #line + 1, #line
    end
    segments[#segments + 1] = { lnum = from[2], scol = scol, ecol = ecol }
  end
  return { kind = "char", segments = segments }
end

---The width of a blockwise region in screen cells: the distance between its two
---corners, and nil for the other two kinds. This is the block's own width, not
---the narrower one the rows under it happen to draw -- Vim replays a block at
---its full width whatever the text at the cursor looks like, while `'[`/`']`
---reach no further than the last line's own end, so a `.` has to be told (D3.2).
---@param buf integer
---@param region bang.Region
---@return integer|nil
function M.block_width(buf, region)
  local normalized = M.normalize(region)
  if not normalized or normalized.kind ~= "block" then
    return nil
  end
  local pos1, line1 = corner(buf, normalized.anchor)
  local pos2, line2 = corner(buf, normalized.cursor)
  local afirst, alast = corner_cell(line1, pos1), corner_char_end(line1, pos1)
  local cfirst, clast = corner_cell(line2, pos2), corner_char_end(line2, pos2)
  -- Vim builds the block from the leftmost of the two corners' first cells and
  -- the rightmost of their last, so a <Tab> or a wide character under either
  -- corner widens it (D-2).
  local right = math.max(alast, clast)
  -- The ends are in buffer order, so `cursor` is the later corner: the one an
  -- exclusive region leaves out, and only while the block stays at least as
  -- wide as the earlier corner's own character without it (#8). Everywhere else
  -- `getregionpos()` applies that itself; here there may be no row of text for
  -- it to apply it to.
  if normalized.exclusive and cfirst > afirst and cfirst - 1 >= alast then
    right = cfirst - 1
  end
  return right - math.min(afirst, cfirst) + 1
end

---Turn a normalized region into one segment per line.
---@param buf integer
---@param region table Result of `M.normalize`.
---@return bang.Resolved|nil, string|nil
function M.resolve(buf, region)
  if math.max(region.anchor.lnum, region.cursor.lnum) > api.nvim_buf_line_count(buf) then
    return nil, "bang: region is outside the buffer"
  end

  if region.kind == "line" then
    local segments = {}
    -- Linewise never carries a width, so `normalize` put the ends in order.
    for lnum = region.anchor.lnum, region.cursor.lnum do
      segments[#segments + 1] = { lnum = lnum, scol = 1, ecol = #get_line(buf, lnum) }
    end
    return { kind = "line", segments = segments }
  end

  if region.kind == "block" then
    return resolve_block(buf, region)
  end

  return resolve_char(buf, region)
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

---Where a written span ends: the last of `count` bytes -- or lines -- counted
---from `start`, which is what `']` takes. A span that received nothing -- zero
---output, an output line carrying no bytes of its own, a block row the command
---cleared or one the block never reached -- has no last byte, so the end stays
---where those bytes would have begun and `']` sits with `'[`. That is where
---`d`, the operator that writes nothing either, leaves them both (#25, #31).
---@param start integer
---@param count integer Bytes or lines written, 0 when none were.
---@return integer
local function span_end(start, count)
  return start + math.max(count, 1) - 1
end

---@param buf integer
---@param resolved bang.Resolved
---@param lines string[]
---@return bang.Written
local function write_charwise(buf, resolved, lines)
  local first = resolved.segments[1]
  local last = resolved.segments[#resolved.segments]
  local scol = first.scol - 1
  if #lines == 0 then
    lines = { "" }
  end
  api.nvim_buf_set_text(buf, first.lnum - 1, scol, last.lnum - 1, last.ecol, lines)
  -- Only a single output line still starts at the region's own column; any
  -- further line begins at column 0.
  local start_col = #lines == 1 and scol or 0
  return {
    from = { first.lnum, scol },
    to = { first.lnum + #lines - 1, span_end(start_col, #lines[#lines]) },
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
  -- region had, and a mark can only sit on a line that still exists. Empty
  -- output writes no line for `']` to end on, so both marks go on the line that
  -- took the region's place -- or on the last line that remains, where the
  -- region ran to the end of the buffer and no line took it. Vim's own marks do
  -- sit past the last line after a run like that; it is `nvim_buf_set_mark()`
  -- that refuses to put one there (#31).
  local count = api.nvim_buf_line_count(buf)
  return {
    from = { math.min(first, count), 0 },
    to = { math.min(span_end(first, #lines), count), 0 },
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
      -- `']` goes on the last byte of the new text. Where the row received no
      -- byte, `span_end` leaves the mark where the block ends on that row: the
      -- character after a cleared block, and past the row's own end where the
      -- block reaches beyond it, both of which is where blockwise `d` puts it
      -- (#8, #25).
      end_col = span_end(#head, #text)
    end
  end
  -- One write for the whole block, and every row is built before it, so a
  -- failure while building leaves the buffer untouched (F9, D7.6). Inside that
  -- one call Neovim still reports each row to a buffer-attach callback, and one
  -- that turns 'modifiable' off between two rows leaves the rows before it
  -- written: a documented limit, `:help bang-differences` (#28). Undoing them
  -- would take back more than this run -- the write is one undo block, and so
  -- is whatever else the same command changed, an earlier run included -- and
  -- under 'undolevels' = -1 it would take back nothing at all.
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
    -- A mark may sit past the last byte of its line, a cursor may not -- and
    -- clamping it back into the line can land it inside a character, which is
    -- no place for a cursor either (#22).
    col = math.min(col, math.max(#line - 1, 0))
    if col > 0 then
      col = col + vim.str_utf_start(line, col + 1)
    end
    api.nvim_win_set_cursor(0, { lnum, col })
  end
  return nil
end

return M
