-- Differential oracle: bang.nvim against Vim's own operator on the same selection.
--
-- `gU` is the clean reference for a charwise or blockwise region. It is a pure
-- per-cell transform with no line-count change, so `tr a-z A-Z` through
-- bang.nvim must land on exactly the same cells. (`tr` works on bytes, but a
-- UTF-8 lead or continuation byte is always >= 0x80, never in a-z, so the two
-- agree on multibyte text with no case as well.) For a linewise region the
-- oracle is the built-in filter, `:{range}!tr a-z A-Z`: #6 ruled the linewise
-- marks against `!`, and the two operators disagree about `']` -- `gU` leaves it
-- on the last byte of the region's last line, `!` in that line's column 1.
-- Nothing here predicts a result: Vim computes it, and the same key sequence is
-- replayed for both arms.
--
-- The text is not the whole result. `'[`, `']` and the cursor are compared
-- against the same oracle (#25), because the write-back derived them from the
-- region rather than from what it wrote: a block whose first or last row the
-- block does not reach, and a `$` block, all landed them a column off. Every
-- case below compares them except the `.` repeat: Neovim nightly rebuilds a
-- block differently there (#12), so that one stays on the text alone.
--
-- Each corpus entry is checked through all three entry points -- Visual `g!`,
-- typed `:'<,'>Bang`, and `run()` with the region rebuilt from the marks --
-- because F2 produced different wrong columns on different paths.

local H = dofile("tests/helpers.lua")

local eq, neq = MiniTest.expect.equality, MiniTest.expect.no_equality

local child = MiniTest.new_child_neovim()

-- The corpus. `keys` ends in Visual mode with the selection made.
--
-- `api_maxcol` marks a selection the mark pair cannot describe on its own: after
-- `CTRL-V $` the `'>` column is the cursor's, so the Lua API needs the explicit
-- "to end of line" column instead.
local CORPUS = {
  ["char single line"] = {
    lines = { "password: hunter2" },
    keys = { "gg", "0", "fh", "v", "$" },
  },
  ["char across two lines"] = {
    lines = { "alpha bravo", "charlie delta" },
    keys = { "gg", "0", "w", "v", "j", "l" },
  },
  ["char ending on an empty line"] = {
    lines = { "aa", "bb", "", "cc" },
    keys = { "gg", "0", "v", "j", "j" },
  },
  ["char to the end of the buffer"] = {
    lines = { "aa", "", "bb" },
    keys = { "gg", "0", "v", "G", "$" },
  },
  ["char with trailing spaces"] = {
    lines = { "ab  ", "cd" },
    keys = { "gg", "0", "v", "$" },
  },
  ["char with multibyte"] = {
    lines = { "x 中文 y", "z" },
    keys = { "gg", "0", "v", "j" },
  },
  ["linewise"] = {
    lines = { "aa", "bb", "cc" },
    keys = { "gg", "V", "j" },
  },
  ["linewise with trailing spaces"] = {
    lines = { "aa  ", "bb", "cc" },
    keys = { "gg", "V", "j" },
  },
  ["block with full-length lines"] = {
    lines = { "abcd", "efgh" },
    keys = { "gg", "0", "l", "<C-v>", "j", "l" },
  },
  ["block whose last line is short"] = {
    lines = { "abcd", "efgh", "ij" },
    keys = { "gg", "0", "3l", "<C-v>", "2j" },
  },
  ["block whose first line is short"] = {
    lines = { "ab", "efgh", "ijkl" },
    keys = { "3G", "0", "3l", "<C-v>", "2k" },
  },
  ["block whose middle line is short"] = {
    lines = { "aaaa", "b", "cccc" },
    keys = { "gg", "0", "2l", "<C-v>", "2j", "l" },
  },
  ["block over an empty line"] = {
    lines = { "abcd", "", "efgh" },
    keys = { "gg", "0", "<C-v>", "2j", "l" },
  },
  ["block over lines with trailing spaces"] = {
    lines = { "ab  ", "cdef", "gh  " },
    keys = { "gg", "0", "l", "<C-v>", "2j", "l" },
  },
  ["block past the end of a line with trailing spaces"] = {
    -- F8's exact shape: the block reaches past line 1's end, and the cells it
    -- does cover there are the line's own trailing spaces. Trimming more than
    -- the padding the plugin itself added eats them.
    lines = { "ab  ", "cdefgh" },
    keys = { "gg", "0", "2l", "<C-v>", "j", "3l" },
  },
  -- §12d block column math: tab, CJK and virtualedit lines. gU is a per-cell
  -- transform, so it is still the oracle; these only add cells the previous
  -- corpus never selected.
  ["block over a tab interior to both segments"] = {
    lines = { "a\tbcd", "e\tfgh" },
    keys = { "gg", "0", "<C-v>", "j", "5l" },
  },
  ["block whose far line is short with a tab on the near line (D-2)"] = {
    -- The far corner clamps to one past line 2's end; the block's left edge must
    -- not slide onto line 1's tab and refuse. gU filters it fine.
    lines = { "a\tbcd", "efghij" },
    keys = { "gg", "0", "fb", "<C-v>", "l", "j" },
  },
  ["block boundary landing inside a tab"] = {
    lines = { "a\tbcd", "e\tfgh" },
    keys = { "gg", "0", "3l", "<C-v>", "j", "3l" },
  },
  ["block boundary landing inside a CJK char"] = {
    lines = { "x中文y", "abcde" },
    keys = { "gg", "0", "l", "<C-v>", "l", "j" },
  },
  ["block over a column of tab-indented code"] = {
    lines = { "\tfoo := 1", "\tbar := 2", "\t}" },
    keys = { "gg", "0", "l", "<C-v>", "2j", "2l" },
  },
  ["block over full-width CJK lines"] = {
    lines = { "a中b", "x文y" },
    keys = { "gg", "0", "<C-v>", "j", "2l" },
  },
  ["ragged block"] = {
    lines = { "abcdef", "ab", "abcd" },
    keys = { "gg", "0", "l", "<C-v>", "2j", "$" },
    api_maxcol = true,
  },
  -- #25's three shapes: a row the block never reaches, and a row whose end it
  -- runs past, are the rows `'[` and `']` used to be a column off on.
  ["block whose first line stops before the block"] = {
    -- Line 1 holds no text of the block at all, so `'[` has no byte of its own
    -- to sit on and goes past the line's end, where the cursor then clamps.
    lines = { "ab", "abcdefgh" },
    keys = { "G", "0", "4l", "<C-v>", "l", "k" },
  },
  ["block whose last line stops before the block"] = {
    -- The mirror image: `']` goes past the last line's end.
    lines = { "abcdefgh", "ab" },
    keys = { "gg", "0", "4l", "<C-v>", "l", "j" },
  },
  ["ragged block whose last line is the longest"] = {
    -- A `$` block runs past every line's end, the longest one included, so `']`
    -- lands one column past its last byte and not on it.
    lines = { "abcd", "abcdefgh" },
    keys = { "gg", "0", "l", "<C-v>", "j", "$" },
    api_maxcol = true,
  },
}

local LABELS = {
  "char single line",
  "char across two lines",
  "char ending on an empty line",
  "char to the end of the buffer",
  "char with trailing spaces",
  "char with multibyte",
  "linewise",
  "linewise with trailing spaces",
  "block with full-length lines",
  "block whose last line is short",
  "block whose first line is short",
  "block whose middle line is short",
  "block over an empty line",
  "block over lines with trailing spaces",
  "block past the end of a line with trailing spaces",
  "block over a tab interior to both segments",
  "block whose far line is short with a tab on the near line (D-2)",
  "block boundary landing inside a tab",
  "block boundary landing inside a CJK char",
  "block over a column of tab-indented code",
  "block over full-width CJK lines",
  "ragged block",
  "block whose first line stops before the block",
  "block whose last line stops before the block",
  "ragged block whose last line is the longest",
}

local params = {}
for _, label in ipairs(LABELS) do
  params[#params + 1] = { label }
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      H.setup_child(child)
      -- A tab is 8 cells, so the tab-block geometry is stable across machines.
      child.o.tabstop = 8
      H.stub_input(child, { "tr a-z A-Z" })
    end,
    post_once = child.stop,
  },
})

local function select_region(entry)
  child.cmd("enew!")
  H.set_lines(child, entry.lines)
  for _, key in ipairs(entry.keys) do
    child.type_keys(key)
  end
end

--- The region the marks describe, in the public vocabulary of D3.4.
---
--- `col + off` for both ends is what F7 requires so that a `virtualedit` anchor
--- past the end of a line survives.
local function region_from_marks(api_maxcol)
  return child.lua(
    [[
      local api_maxcol = ...
      local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
      local finish_col = e[3] + e[4]
      if api_maxcol then
        finish_col = vim.v.maxcol
      end
      return {
        type = vim.fn.visualmode(),
        start = { lnum = s[2], col = s[3] + s[4] },
        finish = { lnum = e[2], col = finish_col },
      }
    ]],
    { api_maxcol == true }
  )
end

--- `'[`, `']` and the cursor, as `getpos()` reports them.
local function positions()
  return child.lua_get([[{
    open = vim.fn.getpos("'["),
    close = vim.fn.getpos("']"),
    cursor = vim.fn.getpos("."),
  }]])
end

--- Whether Vim's own account of the live selection covers any byte of its last
--- line: `getregionpos()` gives column 0 for a line the region does not reach.
local function covers_last_line()
  return child.lua_get([[(function()
    local raw = vim.fn.getregionpos(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
    local last = raw[#raw]
    return last ~= nil and last[1][3] > 0
  end)()]])
end

--- Run Vim's own operator over the selection and report what it left behind.
---
--- `gU` for a charwise or blockwise region; the built-in filter for a linewise
--- one, whose marks #6 ruled against `!` rather than against `gU`.
---
--- One rule separates the plugin's positions from the oracle's, and it is the
--- ruling of #25: `'[` and `']` bracket the bytes the run wrote. Vim's operators
--- mark the region instead, and a region can end where no byte was written --
--- past the last byte of a line a block reaches beyond, and on the line break a
--- charwise `$` selects. There the plugin's `']` sits one column to the left, on
--- the last byte it did write. Where the region covers no byte of that line at
--- all -- a row the block never reaches -- the run wrote nothing there, so
--- there is no byte to the left either and both marks sit past the line's end
--- together.
---
--- The rule assumes the command keeps every row's width, as `tr a-z A-Z` does.
--- A command that clears or shrinks a row moves the plugin's `']` by the
--- cleared-row half of the ruling, which `covered`, taken from the region,
--- cannot see: a corpus command of that kind needs the output as well.
local function oracle(entry)
  select_region(entry)
  local linewise = child.lua_get("vim.fn.mode()") == "V"
  local covered = covers_last_line()
  if linewise then
    child.type_keys("<Esc>")
    child.cmd("silent! '<,'>!tr a-z A-Z")
  else
    child.type_keys("gU")
  end
  local expected = {
    name = linewise and ":{range}!" or "gU",
    lines = H.get_lines(child),
    pos = positions(),
  }
  local close = expected.pos.close
  if covered and close[3] > #(expected.lines[close[2]] or "") then
    close[3] = close[3] - 1
  end
  return expected
end

--- Compare one entry point's result, text and positions, against the oracle.
local function expect_oracle(entry_point, label, expected)
  local where = ("%s: %s differs from %s"):format(label, entry_point, expected.name)
  eq(H.get_lines(child), expected.lines, { fail_reason = where })
  eq(positions(), expected.pos, { fail_reason = where .. " in '[, '] or the cursor" })
end

T["differential"] = MiniTest.new_set({ parametrize = params })

T["differential"]["F2 every entry point matches Vim's own operator on the same selection"] = function(
  label
)
  local entry = CORPUS[label]

  -- The oracle: Vim filters the selection itself.
  local expected = oracle(entry)
  neq(expected.lines, entry.lines, {
    fail_reason = ("%s: %s changed nothing, so the comparison would be vacuous"):format(
      label,
      expected.name
    ),
  })

  -- Visual `g!`.
  select_region(entry)
  child.type_keys("g!")
  expect_oracle("Visual g!", label, expected)

  -- Typed `:'<,'>Bang`.
  select_region(entry)
  child.type_keys("<Esc>")
  H.type_cmd(child, "'<,'>Bang tr a-z A-Z")
  expect_oracle(":'<,'>Bang", label, expected)

  -- `run()` with the region rebuilt from the marks.
  select_region(entry)
  child.type_keys("<Esc>")
  local region = region_from_marks(entry.api_maxcol)
  child.cmd("enew!")
  H.set_lines(child, entry.lines)
  local res = H.run(child, "tr a-z A-Z", region)
  eq(res.ok, true, { fail_reason = label .. ": run() refused (" .. tostring(res.msg) .. ")" })
  expect_oracle("run()", label, expected)
end

-- §3.2 `.` on a block --------------------------------------------------------

T["D3.2 . after a blockwise g! matches Vim's own redo of gU"] = function()
  -- Vim rebuilds the block at the cursor on a redo. Each case holds the same
  -- text twice: the second copy is where `.` lands, and gU's own `.` decides
  -- which cells that covers -- `$`, a tab or a wide char on the edge are
  -- exactly where the marks the opfunc can read stop describing it.
  -- NOTE: no shape here has a far line shorter than the block. Neovim
  -- nightly's own redo narrows or moves the block there, while stable and 0.11
  -- keep the width :help visual-repeat promises; the operator test pins that.
  -- For the same reason this case compares the text alone: where the redone
  -- block itself differs by version (#12), `'[`, `']` and the cursor cannot be
  -- held to one answer.
  local cases = {
    {
      { "abcd", "efgh", "", "abcd", "efgh" },
      { "gg", "0", "l", "<C-v>", "j", "l" },
      { "4G", "0", "l" },
    },
    {
      { "abcdef", "ab", "", "abcdef", "ab" },
      { "gg", "0", "l", "<C-v>", "j", "$" },
      { "4G", "0", "l" },
    },
    {
      { "x中文y", "abcde", "", "x中文y", "abcde" },
      { "gg", "0", "l", "<C-v>", "l", "j" },
      { "4G", "0", "l" },
    },
  }
  for i, c in ipairs(cases) do
    local lines, select, target = c[1], c[2], c[3]
    local entry = { lines = lines, keys = select }

    select_region(entry)
    child.type_keys("gU")
    child.type_keys(unpack(target))
    child.type_keys(".")
    local expected = H.get_lines(child)
    neq(expected, lines, { fail_reason = ("case %d: gU changed nothing"):format(i) })

    select_region(entry)
    H.stub_input(child, { "tr a-z A-Z" })
    child.type_keys("g!")
    child.type_keys(unpack(target))
    child.type_keys(".")
    eq(H.get_lines(child), expected, {
      fail_reason = ("case %d: . after g! differs from . after gU (%s)"):format(
        i,
        vim.inspect(expected)
      ),
    })
  end
end

-- §12c F7 virtualedit -------------------------------------------------------

T["F7 a virtualedit block with an anchor past the end of a line matches gU"] = function()
  -- `getpos()` carries `coladd` in its 4th element, so `col + off` recovers the
  -- virtual column and no new region field is needed for a tab-free line.
  --
  -- The text alone is compared here. Under 'virtualedit' the block stands past
  -- line 1's end, and neither of Vim's positions there can be reproduced: `gU`
  -- gives `'[` and `']` a `coladd` -- `getpos()`'s 4th element -- and
  -- `nvim_buf_set_mark()` takes a byte column and nothing else; and `gU` leaves
  -- the cursor out in that virtual space, where a cursor may only stand while
  -- 'virtualedit' is on, so the plugin puts it on the line's last byte.
  child.o.virtualedit = "all"
  local lines = { "ab", "cdefgh", "ij" }
  local entry = { lines = lines, keys = { "gg", "0", "4l", "<C-v>", "2j", "l" } }

  local expected = oracle(entry).lines
  neq(expected, lines, { fail_reason = "gU changed nothing, so the comparison would be vacuous" })

  select_region(entry)
  child.type_keys("g!")
  eq(H.get_lines(child), expected, { fail_reason = "Visual g! differs from gU" })

  select_region(entry)
  child.type_keys("<Esc>")
  H.type_cmd(child, "'<,'>Bang tr a-z A-Z")
  eq(H.get_lines(child), expected, { fail_reason = ":'<,'>Bang differs from gU" })

  select_region(entry)
  child.type_keys("<Esc>")
  local region = region_from_marks(false)
  child.cmd("enew!")
  H.set_lines(child, lines)
  local res = H.run(child, "tr a-z A-Z", region)
  eq(res.ok, true, { fail_reason = "run() refused (" .. tostring(res.msg) .. ")" })
  eq(H.get_lines(child), expected, { fail_reason = "run() differs from gU" })
end

T["F7 virtualedit = block behaves the same as virtualedit = all"] = function()
  -- Text only, for the same reason as the case above.
  child.o.virtualedit = "block"
  local lines = { "ab", "cdefgh", "ij" }
  local entry = { lines = lines, keys = { "gg", "0", "4l", "<C-v>", "2j", "l" } }

  local expected = oracle(entry).lines
  neq(expected, lines)

  select_region(entry)
  child.type_keys("g!")
  eq(H.get_lines(child), expected)
end

-- §12d D-2 and the D-1 residual --------------------------------------------

T["D-2 a block over a tab-bearing line whose far line is short is filtered, not refused"] = function()
  -- The minimal shape from §12d: the far corner clamps to one past line 2's
  -- end, which used to slide the block's left edge onto line 1's tab and trip a
  -- spurious "half a tab" refusal. gU is the oracle and does not refuse.
  local lines = { "a\tbcd", "efghij" }
  local entry = { lines = lines, keys = { "gg", "0", "fb", "<C-v>", "l", "j" } }

  local expected = oracle(entry)
  neq(expected.lines, lines, {
    fail_reason = "gU changed nothing, so the comparison would be vacuous",
  })

  select_region(entry)
  child.type_keys("g!")
  expect_oracle("Visual g!", "D-2", expected)

  select_region(entry)
  child.type_keys("<Esc>")
  H.type_cmd(child, "'<,'>Bang tr a-z A-Z")
  expect_oracle(":'<,'>Bang", "D-2", expected)
end

T["D-2 no tab/CJK boundary is refused where gU accepts it"] = function()
  -- The generalisation §12d asks to verify: with the straddle refusal gone,
  -- every boundary case gU filters, bang filters too. A refusal survives only
  -- where gU itself would refuse -- and gU never refuses a per-cell transform,
  -- so bang must not refuse any of these through the Visual path.
  local cases = {
    { { "a\tbcd", "efghij" }, { "gg", "0", "fb", "<C-v>", "l", "j" } },
    { { "a\tbcd", "e\tfgh" }, { "gg", "0", "3l", "<C-v>", "j", "3l" } },
    { { "x中文y", "abcde" }, { "gg", "0", "l", "<C-v>", "l", "j" } },
    { { "\tfoo := 1", "\t}" }, { "gg", "0", "l", "<C-v>", "j", "2l" } },
  }
  for i, c in ipairs(cases) do
    local entry = { lines = c[1], keys = c[2] }
    local expected = oracle(entry)

    select_region(entry)
    -- Each iteration presses g! once, so restub the single answer per case; the
    -- shared hook stubs only one, which case 1 would consume (D4.2: an
    -- unanswered prompt cancels and writes nothing).
    H.stub_input(child, { "tr a-z A-Z" })
    H.reset_notifications(child)
    child.type_keys("g!")
    expect_oracle("g!", ("case %d"):format(i), expected)
    eq(#H.notifications(child), 0, { fail_reason = ("case %d: g! notified a refusal"):format(i) })
  end
end

T["D-1 residual: a virtualedit block past a tab-led line diverges from gU"] = function()
  -- KNOWN RESIDUAL, not a guarantee (§12d D-1, §12c F7): `col + off` mixes byte
  -- and cell counts, so an anchor in virtual space past a line that begins with
  -- a tab lands the block on the wrong columns. §12d rules this stays unfixed
  -- for v0.1 and documented.
  --
  -- The residual is selection-sensitive (some past-EOL columns already land
  -- right), so this pins the *documented fact* that it still exists somewhere:
  -- at least one of these virtualedit + tab + past-EOL selections must still
  -- disagree with gU. When every one matches, the residual is gone -- this test
  -- trips, and that is the signal to delete the README/vimdoc residual line and
  -- fold these selections into the differential corpus. It asserts a known bug,
  -- never a guarantee.
  child.o.virtualedit = "all"
  child.o.tabstop = 8
  local probes = {
    { { "\tx", "\tabcdefgh" }, { "gg", "0", "$", "3l", "<C-v>", "j" } },
    { { "\tx", "\tabcdefgh" }, { "gg", "0", "$", "5l", "<C-v>", "j" } },
    { { "\tx", "\tabcdefgh" }, { "gg", "0", "$", "l", "<C-v>", "j", "2l" } },
    { { "\ta", "bcdefgh" }, { "gg", "0", "A", "<Esc>", "<C-v>", "j" } },
  }
  local diverged, sample = 0, nil
  for _, probe in ipairs(probes) do
    local entry = { lines = probe[1], keys = probe[2] }

    select_region(entry)
    child.type_keys("gU")
    local expected = H.get_lines(child)

    select_region(entry)
    child.type_keys("g!")
    local got = H.get_lines(child)

    if not vim.deep_equal(got, expected) then
      diverged = diverged + 1
      sample = ("keys=%s got=%s gU=%s"):format(
        vim.inspect(probe[2]),
        vim.inspect(got),
        vim.inspect(expected)
      )
    end
  end

  neq(diverged, 0, {
    fail_reason = "every virtualedit+tab+past-EOL probe now matches gU: the D-1 residual "
      .. "is gone. Delete the §12c F7 / §12d D-1 docs residual line and convert these "
      .. "probes into corpus entries asserting equality.",
  })
  MiniTest.add_note(
    ("D-1 residual present in %d/%d probes; %s"):format(diverged, #probes, sample or "")
  )
end

-- §12f Issue #23 NUL width -------------------------------------------------

T["#23 a block edge after a NUL lands on the cells gU uses, under either 'display'"] = function()
  -- A NUL has no fixed width: 'display' decides whether the screen shows it as
  -- "^@" or as "<00>". The block's left edge is measured from the text before
  -- it, so the sibling line without a NUL is where a wrong measure shows: the
  -- block lands on a different column than gU picks. The second pass turns on
  -- "uhex", which no single hardcoded width can satisfy alongside the first.
  local lines = { "a\0bZZ", "abcdefgh" }
  local entry = { lines = lines, keys = { "gg", "0", "3l", "<C-v>", "j" } }

  for _, display in ipairs({ child.o.display, "uhex" }) do
    child.o.display = display

    select_region(entry)
    child.type_keys("gU")
    local expected = H.get_lines(child)
    neq(expected, lines, {
      fail_reason = display .. ": gU changed nothing, so the comparison would be vacuous",
    })

    select_region(entry)
    -- One g! per pass, and the shared hook stubs a single answer (D4.2: an
    -- unanswered prompt cancels and writes nothing).
    H.stub_input(child, { "tr a-z A-Z" })
    child.type_keys("g!")
    eq(H.get_lines(child), expected, {
      fail_reason = ("display=%s: g! landed on different cells than gU"):format(display),
    })
  end
end

return T
