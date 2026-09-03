-- Acceptance tests for the engine: `require("bang").run(cmd, region, opts)`.
--
-- Regions are constructed directly, so nothing here depends on how the operator
-- or `:Bang` build them. Each case is named after the DESIGN.md decision it
-- pins; the README's "guarantees -> tests" table cites these names.

local H = dofile("tests/helpers.lua")

local eq, neq = MiniTest.expect.equality, MiniTest.expect.no_equality
local WARN, ERROR = 3, 4

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      H.setup_child(child, { plugin = false })
    end,
    post_once = child.stop,
  },
})

-- §5.1 / §7.3 Regions -------------------------------------------------------

T["D7.3 charwise output replaces exactly the selected bytes"] = function()
  H.set_lines(child, { "password: hunter2" })
  local res = H.run(child, "base64", H.charwise(1, 11, 1, 17))
  eq(res.ok, true)
  eq(H.get_lines(child), { "password: aHVudGVyMg==" })
end

T["D5.1 a multibyte charwise region survives byte for byte"] = function()
  H.set_lines(child, { "x 中文 y" })
  local res = H.run(child, "base64", H.charwise(1, 2, 1, 8))
  eq(res.ok, true)
  eq(H.get_lines(child), { "xIOS4reaWhw== y" })
end

T["D7.3 a charwise region spanning two lines is replaced as one span"] = function()
  H.set_lines(child, { "aXb", "cYd" })
  local res = H.run(child, "tr bc BC", H.charwise(1, 2, 2, 1))
  eq(res.ok, true)
  eq(H.get_lines(child), { "aXB", "CYd" })
end

T["D5.1 an empty line is an empty region at column 0"] = function()
  H.set_lines(child, { "a", "", "b" })
  local res = H.run(child, "printf Z", H.charwise(2, 0, 2, 0))
  eq(res.ok, true)
  eq(H.get_lines(child), { "a", "Z", "b" })
end

-- §5.2 stdin ----------------------------------------------------------------

T["D5.2 charwise stdin carries no trailing newline"] = function()
  local log = H.use_log_shell(child)
  H.set_lines(child, { "password: hunter2" })
  H.run(child, "filter", H.charwise(1, 11, 1, 17))
  eq(H.log_shell(child, log).stdin, "hunter2")
end

T["D5.2 linewise stdin ends with a trailing newline"] = function()
  local log = H.use_log_shell(child)
  H.set_lines(child, { "one", "two" })
  H.run(child, "filter", H.linewise(1, 2))
  eq(H.log_shell(child, log).stdin, "one\ntwo\n")
end

T["D5.2 blockwise stdin ends with a trailing newline"] = function()
  local log = H.use_log_shell(child)
  H.set_lines(child, { "1 c", "2 a", "3 b" })
  H.run(child, "filter", H.blockwise(1, 3, 3, 3))
  eq(H.log_shell(child, log).stdin, "c\na\nb\n")
end

T["D5.2 an empty region sends empty stdin"] = function()
  local log = H.use_log_shell(child)
  H.set_lines(child, { "a", "", "b" })
  H.run(child, "filter", H.charwise(2, 0, 2, 0))
  eq(H.log_shell(child, log).stdin, "")
end

T["D5.2 buffer text reaches the command inert to the shell"] = function()
  local payload = [[$(id) `whoami` 'x' "y"]]
  H.set_lines(child, { payload })
  local res = H.run(child, "cat", H.linewise(1, 1))
  eq(res.ok, true)
  eq(H.get_lines(child), { payload })
end

-- §5.3 / §5.4 / §5.5 Blockwise ---------------------------------------------

T["D7.4 a blockwise region filters one column"] = function()
  H.set_lines(child, { "1 c", "2 a", "3 b" })
  local res = H.run(child, "sort", H.blockwise(1, 3, 3, 3))
  eq(res.ok, true)
  eq(H.get_lines(child), { "1 a", "2 b", "3 c" })
end

T["D5.3 a ragged block extends to each line's end"] = function()
  H.set_lines(child, { "abcdef", "ab", "abcd" })
  local res = H.run(child, "tr a-z A-Z", H.blockwise(1, 2, 3, H.MAXCOL))
  eq(res.ok, true)
  eq(H.get_lines(child), { "aBCDEF", "aB", "aBCD" })
end

T["D5.4 a short line inside a block is padded on write-back"] = function()
  -- "b" does not reach the block, so its line is padded with spaces up to the
  -- block's start column and the output row is written there. The command emits
  -- a fixed "X" per row, so the assertion does not depend on how wide
  -- `getregion()` pads the segment it hands over.
  H.set_lines(child, { "aaaa", "b", "cccc" })
  local res = H.run(child, "sed 's/.*/X/'", H.blockwise(1, 3, 3, 4))
  eq(res.ok, true)
  eq(H.get_lines(child), { "aaX", "b X", "ccX" })
end

T["D5.4 a short line still contributes a row to the command's stdin"] = function()
  -- The row mapping is the point of D5.4: sorting a column must keep line 2
  -- lined up with the second input row.
  local log = H.use_log_shell(child)
  H.set_lines(child, { "aaaa", "b", "cccc" })
  H.run(child, "filter", H.blockwise(1, 3, 3, 4))
  local rows = vim.split(H.log_shell(child, log).stdin, "\n", { plain = true })
  eq(#rows, 4, { fail_reason = "three block rows plus the trailing newline" })
  eq(rows[1], "aa")
  eq(rows[3], "cc")
  neq(rows[2], "b", { fail_reason = "the short line must be padded, not passed through" })
  eq(rows[2]:match("^ *$") ~= nil, true)
end

T["D7.4 a blockwise line-count mismatch refuses and names both counts"] = function()
  H.set_lines(child, { "x b", "y a", "z b" })
  local before = H.get_lines(child)
  local res = H.run(child, "sort -u", H.blockwise(1, 3, 3, 3))
  eq(res.ok, false)
  eq(H.get_lines(child), before)
  eq(type(res.msg), "string")
  -- two output lines against three region lines
  neq(res.msg:find("2", 1, true), nil)
  neq(res.msg:find("3", 1, true), nil)
end

T["D-2 (supersedes D5.5) a charwise boundary inside a tab includes the tab whole"] = function()
  -- §12d deletes D5.5's tab-boundary refusal: a <Tab> straddling a boundary is
  -- included whole and filtered, as Vim does. Bytes 1-3 of "ab\tcd" are a, b and
  -- the tab; `tr` uppercases the letters and leaves the tab, so the region is
  -- filtered, not refused.
  H.set_lines(child, { "ab\tcd" })
  local res = H.run(child, "tr a-z A-Z", H.charwise(1, 1, 1, 3))
  eq(res.ok, true, {
    fail_reason = "a tab on the boundary must no longer be refused (" .. tostring(res.msg) .. ")",
  })
  eq(H.get_lines(child), { "AB\tcd" })
end

T["D5.5 a tab that no boundary falls inside is filtered normally"] = function()
  -- Boundary case for D5.5: the tab is *inside* the region, not on its edge.
  H.set_lines(child, { "a\tb" })
  local res = H.run(child, "tr a-z A-Z", H.charwise(1, 1, 1, 3))
  eq(res.ok, true)
  eq(H.get_lines(child), { "A\tB" })
end

-- §6.1 Process --------------------------------------------------------------

T["D6.1 argv is &shell then &shellcmdflag split on whitespace then the command"] = function()
  local log = H.use_log_shell(child, "-a  -b")
  H.set_lines(child, { "one" })
  H.run(child, "sort -r", H.linewise(1, 1))
  eq(H.log_shell(child, log).argv, { "-a", "-b", "sort -r" })
end

T["D6.1 the command runs in the current working directory"] = function()
  local log = H.use_log_shell(child)
  local dir =
    child.lua_get("(function() local d = vim.fn.tempname() vim.fn.mkdir(d, 'p') return d end)()")
  child.cmd("lcd " .. dir)
  H.set_lines(child, { "one" })
  H.run(child, "sort", H.linewise(1, 1))
  eq(H.log_shell(child, log).cwd, child.lua_get("vim.fn.resolve(...)", { dir }))
end

T["D6.1 % expands to the buffer name before the command runs"] = function()
  local path = child.lua_get("vim.fn.tempname()")
  child.cmd("file " .. path)
  H.set_lines(child, { "one" })
  local res = H.run(child, "echo %", H.linewise(1, 1))
  eq(res.ok, true)
  eq(H.get_lines(child), { path })
end

T["D6.1 a backslash the shell needs survives expansion"] = function()
  -- `!` only strips a backslash before `%`, `#` and `!`; every other backslash
  -- reaches the shell (verified: `:2,3!printf 'x\ny\n'` yields two lines).
  -- D2.1 makes that the contract, so `printf`, `sed` and `grep -P` keep working.
  local start = { "a", "b", "c", "d" }
  child.cmd("enew!")
  H.set_lines(child, start)
  child.cmd([[silent! 2,3!printf 'x\ny\n']])
  local builtin = H.get_lines(child)

  child.cmd("enew!")
  H.set_lines(child, start)
  local res = H.run(child, [[printf 'x\ny\n']], H.linewise(2, 3))
  eq(res.ok, true)
  eq(H.get_lines(child), builtin)
  eq(H.get_lines(child), { "a", "x", "y", "d" })
end

T["D6.1 $VAR is not expanded before the shell sees it"] = function()
  -- The expansion is `cmdline-special` only, not `expandcmd()`, which would also
  -- expand environment variables (verified: `:%!printf '$HOME'` prints `$HOME`).
  local start, cmd = { "a", "b" }, [[printf '$HOME']]
  child.cmd("enew!")
  H.set_lines(child, start)
  child.cmd("silent! 1,2!" .. cmd)
  local builtin = H.get_lines(child)

  child.cmd("enew!")
  H.set_lines(child, start)
  local res = H.run(child, cmd, H.linewise(1, 2))
  eq(res.ok, true)
  eq(H.get_lines(child), builtin)
  eq(H.get_lines(child), { "$HOME" })
end

T["D6.1 a backslash-escaped % reaches the shell as a literal %"] = function()
  H.set_lines(child, { "one" })
  local res = H.run(child, "echo \\%", H.linewise(1, 1))
  eq(res.ok, true)
  eq(H.get_lines(child), { "%" })
end

-- §6.2 Timeout and interrupt ------------------------------------------------

T["D6.2 a timeout leaves the buffer untouched and reports the timeout"] = function()
  H.setup(child, { timeout = 200 })
  H.set_lines(child, { "one", "two" })
  local before = H.get_lines(child)
  local res = H.run(child, "sleep 30", H.linewise(1, 2))
  eq(res.ok, false)
  eq(H.get_lines(child), before)
  eq(type(res.msg), "string")
  neq(res.msg:lower():find("timed out", 1, true), nil)
  neq(res.msg:find("200", 1, true), nil)
end

T["D6.2 a run well inside the timeout is not reported as one"] = function()
  H.setup(child, { timeout = 10000 })
  H.set_lines(child, { "one" })
  local res = H.run(child, "sleep 0.05; tr a-z A-Z", H.linewise(1, 1))
  eq(res.ok, true)
  eq(H.get_lines(child), { "ONE" })
end

T["D6.2 Ctrl-C during a run is reported as an interrupt"] = function()
  MiniTest.skip(
    "Does not reproduce headless: sending SIGINT to vim.uv.os_getpid() kills the "
      .. "embedded child Neovim outright ('ch N was closed by the peer') instead of "
      .. "setting got_int, so the interrupt branch of D6.2 cannot be observed from a "
      .. "child process. Verify by hand in an interactive Neovim."
  )
end

-- §6.3 / §6.4 Failure and output -------------------------------------------

T["D6.3 a non-zero exit leaves the buffer untouched"] = function()
  H.set_lines(child, { "x: {nope}" })
  local before = H.get_lines(child)
  local res = H.run(child, "jq .", H.linewise(1, 1))
  eq(res.ok, false)
  eq(H.get_lines(child), before)
end

T["D6.4 a non-zero exit notifies stderr at ERROR with the exit code"] = function()
  H.set_lines(child, { "one" })
  H.run(child, "echo boom >&2; exit 7", H.linewise(1, 1))
  local notes = H.notifications(child)
  eq(#notes, 1)
  eq(notes[1].level, ERROR)
  neq(notes[1].msg:find("boom", 1, true), nil)
  neq(notes[1].msg:find("7", 1, true), nil)
end

T["D6.4 exit 0 with stderr writes the buffer and notifies at WARN"] = function()
  H.set_lines(child, { "one" })
  local res = H.run(child, "tr a-z A-Z; echo note >&2", H.linewise(1, 1))
  eq(res.ok, true)
  eq(H.get_lines(child), { "ONE" })
  local notes = H.notifications(child)
  eq(#notes, 1)
  eq(notes[1].level, WARN)
  neq(notes[1].msg:find("note", 1, true), nil)
end

T["D6.4 exit 0 with no stderr notifies nothing"] = function()
  H.set_lines(child, { "one" })
  local res = H.run(child, "tr a-z A-Z", H.linewise(1, 1))
  eq(res.ok, true)
  eq(#H.notifications(child), 0)
end

T["D6.3 opts.bang writes the region despite a non-zero exit"] = function()
  H.set_lines(child, { "one" })
  local res = H.run(child, "echo OUT; echo ERR >&2; exit 3", H.linewise(1, 1), { bang = true })
  eq(res.ok, true)
  eq(H.get_lines(child), { "OUT", "ERR" })
end

T["D6.4 replace mode writes stdout followed by stderr"] = function()
  H.setup(child, { on_error = "replace" })
  H.set_lines(child, { "one" })
  local res = H.run(child, "echo OUT; echo ERR >&2; exit 3", H.linewise(1, 1))
  eq(res.ok, true)
  eq(H.get_lines(child), { "OUT", "ERR" })
end

T["D6.4 replace mode notifies nothing"] = function()
  H.setup(child, { on_error = "replace" })
  H.set_lines(child, { "one" })
  H.run(child, "echo ERR >&2; exit 3", H.linewise(1, 1))
  eq(#H.notifications(child), 0)
end

T["D6.4 opts.bang notifies nothing"] = function()
  H.set_lines(child, { "one" })
  H.run(child, "echo ERR >&2; exit 3", H.linewise(1, 1), { bang = true })
  eq(#H.notifications(child), 0)
end

T["D6.5 notifications are emitted through vim.schedule"] = function()
  H.set_lines(child, { "one" })
  local res = child.lua(
    [[
      local cmd, region = ...
      _G.bang_notifications = {}
      local ok = require("bang").run(cmd, region)
      return { ok = ok, immediate = #_G.bang_notifications }
    ]],
    { "echo boom >&2; exit 7", H.linewise(1, 1) }
  )
  eq(res.ok, false)
  eq(res.immediate, 0)
  eq(#H.notifications(child), 1)
end

-- §7.1 Trailing newline -----------------------------------------------------

T["D7.1 strips exactly one trailing newline"] = function()
  -- One trailing newline: gone.
  H.set_lines(child, { "[X]" })
  local res = H.run(child, "echo out", H.charwise(1, 2, 1, 2))
  eq(res.ok, true)
  eq(H.get_lines(child), { "[out]" })

  -- Two: exactly one is stripped, so an empty line survives.
  H.set_lines(child, { "[X]" })
  res = H.run(child, "echo out; echo", H.charwise(1, 2, 1, 2))
  eq(res.ok, true)
  eq(H.get_lines(child), { "[out", "]" })
end

T["D7.1 output without a trailing newline is written as is"] = function()
  H.set_lines(child, { "[X]" })
  local res = H.run(child, "printf out", H.charwise(1, 2, 1, 2))
  eq(res.ok, true)
  eq(H.get_lines(child), { "[out]" })
end

T["D7.1 internal newlines split a charwise region across lines"] = function()
  H.set_lines(child, { "[X]" })
  local res = H.run(child, "echo a; echo b; echo c", H.charwise(1, 2, 1, 2))
  eq(res.ok, true)
  eq(H.get_lines(child), { "[a", "b", "c]" })
end

-- §7.2 Linewise -------------------------------------------------------------

T["D7.2 linewise sort replaces the range"] = function()
  H.set_lines(child, { "c", "a", "b" })
  local res = H.run(child, "sort", H.linewise(1, 3))
  eq(res.ok, true)
  eq(H.get_lines(child), { "a", "b", "c" })
end

T["D7.2 zero-byte output deletes the lines"] = function()
  H.set_lines(child, { "a", "b", "c", "d" })
  local res = H.run(child, "true", H.linewise(2, 3))
  eq(res.ok, true)
  eq(H.get_lines(child), { "a", "d" })
end

T["D7.2 a lone newline becomes one empty line"] = function()
  H.set_lines(child, { "a", "b", "c", "d" })
  local res = H.run(child, "echo", H.linewise(2, 3))
  eq(res.ok, true)
  eq(H.get_lines(child), { "a", "", "d" })
end

T["D7.2 linewise output matches the built-in ! on the same buffer"] = function()
  local start = { "a", "b", "c", "d" }
  local cases = { "echo x; echo y", "true", "echo", "sort", "echo '   x'; echo '   y'" }
  for _, cmd in ipairs(cases) do
    child.cmd("enew!")
    H.set_lines(child, start)
    child.cmd("silent! 2,3!" .. cmd)
    local builtin = { lines = H.get_lines(child), cursor = child.api.nvim_win_get_cursor(0) }

    child.cmd("enew!")
    H.set_lines(child, start)
    local res = H.run(child, cmd, H.linewise(2, 3))
    eq(res.ok, true)
    local bang = { lines = H.get_lines(child), cursor = child.api.nvim_win_get_cursor(0) }

    eq(bang, builtin, { fail_reason = "parity with built-in ! for: " .. cmd })
  end
end

-- §7.5 Marks, cursor, undo, registers --------------------------------------

T["D7.5 the cursor lands at the start of a linewise region"] = function()
  H.set_lines(child, { "a", "c", "b", "d" })
  child.api.nvim_win_set_cursor(0, { 4, 0 })
  local res = H.run(child, "sort", H.linewise(2, 3))
  eq(res.ok, true)
  eq(child.api.nvim_win_get_cursor(0), { 2, 0 })
end

T["D7.5 the linewise cursor lands on the first non-blank of the new text"] = function()
  -- Not column 0: `!` goes to the first non-blank of the first new line
  -- (verified: `:2,3!printf '   x\n   y\n'` leaves the cursor at { 2, 3 }).
  -- Output without leading blanks cannot tell the two readings apart.
  local start, cmd = { "a", "b", "c", "d" }, "echo '   x'; echo '   y'"

  child.cmd("enew!")
  H.set_lines(child, start)
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.cmd("silent! 2,3!" .. cmd)
  local builtin = { lines = H.get_lines(child), cursor = child.api.nvim_win_get_cursor(0) }

  child.cmd("enew!")
  H.set_lines(child, start)
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  local res = H.run(child, cmd, H.linewise(2, 3))
  eq(res.ok, true)
  eq({ lines = H.get_lines(child), cursor = child.api.nvim_win_get_cursor(0) }, builtin)
  eq(H.get_lines(child), { "a", "   x", "   y", "d" })
  eq(child.api.nvim_win_get_cursor(0), { 2, 3 })
end

T["D7.5 the linewise cursor is column 0 when the first new line is empty"] = function()
  -- Boundary of "first non-blank": a blank-only line has none.
  local start, cmd = { "a", "b", "c", "d" }, "echo; echo '   y'"

  child.cmd("enew!")
  H.set_lines(child, start)
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.cmd("silent! 2,3!" .. cmd)
  local builtin = { lines = H.get_lines(child), cursor = child.api.nvim_win_get_cursor(0) }

  child.cmd("enew!")
  H.set_lines(child, start)
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  local res = H.run(child, cmd, H.linewise(2, 3))
  eq(res.ok, true)
  eq({ lines = H.get_lines(child), cursor = child.api.nvim_win_get_cursor(0) }, builtin)
  eq(H.get_lines(child), { "a", "", "   y", "d" })
  eq(child.api.nvim_win_get_cursor(0), { 2, 0 })
end

T["D7.5 '[ and '] bracket the inserted text"] = function()
  H.set_lines(child, { "[X]" })
  local res = H.run(child, "printf 'abc'", H.charwise(1, 2, 1, 2))
  eq(res.ok, true)
  eq(H.get_lines(child), { "[abc]" })
  eq(child.lua_get('vim.fn.getpos("\'[")'), { 0, 1, 2, 0 })
  eq(child.lua_get('vim.fn.getpos("\']")'), { 0, 1, 4, 0 })
end

T["D7.5 one undo restores the buffer after a blockwise run"] = function()
  H.set_lines(child, { "1 c", "2 a", "3 b" })
  local before = H.get_lines(child)
  local res = H.run(child, "sort", H.blockwise(1, 3, 3, 3))
  eq(res.ok, true)
  neq(H.get_lines(child), before)
  child.type_keys("u")
  eq(H.get_lines(child), before)
end

--- The named marks a case sets and the Visual marks, as `getpos()` reports them.
local function marks()
  return child.lua_get([[{
    a = vim.fn.getpos("'a"),
    b = vim.fn.getpos("'b"),
    lt = vim.fn.getpos("'<"),
    gt = vim.fn.getpos("'>"),
  }]])
end

T["D7.5 a linewise run keeps marks the way the built-in ! does"] = function()
  -- The built-in moves marks from the old lines onto the new ones and deletes
  -- only those on lines the output no longer has ('cpo-R'). Same count and more
  -- lines map every mark the same way; fewer lines is the boundary where a mark
  -- inside the region is lost while the ones below still shift.
  local start = { "b", "a", "c", "d", "e" }
  local function place_marks()
    child.cmd("enew!")
    H.set_lines(child, start)
    child.type_keys("2G", "ma", "5G", "mb", "gg", "V", "2j", "<Esc>")
  end

  for _, cmd in ipairs({ "sort", "sed p" }) do
    place_marks()
    child.cmd("silent! 1,3!" .. cmd)
    local builtin = { lines = H.get_lines(child), marks = marks() }

    place_marks()
    local res = H.run(child, cmd, H.linewise(1, 3))
    eq(res.ok, true)
    eq(
      { lines = H.get_lines(child), marks = marks() },
      builtin,
      { fail_reason = "parity with built-in ! for: " .. cmd }
    )
  end

  place_marks()
  child.cmd("silent! 1,3!head -1")
  local builtin = marks()
  place_marks()
  local res = H.run(child, "head -1", H.linewise(1, 3))
  eq(res.ok, true)
  eq(H.get_lines(child), { "b", "d", "e" })
  local bang = marks()
  eq(bang.a, builtin.a, { fail_reason = "a mark on a line the output dropped must be deleted" })
  eq(bang.b, builtin.b, { fail_reason = "a mark below the region must shift with it" })
  eq(bang.lt, builtin.lt)
  -- `'>` sat on a dropped line. The built-in leaves it on the region's first
  -- line; here it lands on the first line after the kept text, as after :delete.
  eq(bang.gt[2], 2)
end

T["D7.5 a blockwise run keeps every mark and the Visual marks"] = function()
  H.set_lines(child, { "1 c", "2 a", "3 b", "x" })
  child.type_keys("2G", "ma", "4G", "mb", "gg", "0", "2l", "<C-v>", "2j", "<Esc>")
  local before = marks()
  local res = H.run(child, "sort", H.blockwise(1, 3, 3, 3))
  eq(res.ok, true)
  eq(H.get_lines(child), { "1 a", "2 b", "3 c", "x" })
  eq(marks(), before)
end

T["D7.5 a one-line run keeps a mark on that line"] = function()
  -- Boundary: one line replaced by one line.
  H.set_lines(child, { "one", "two" })
  child.type_keys("gg", "ma")
  local res = H.run(child, "tr a-z A-Z", H.linewise(1, 1))
  eq(res.ok, true)
  eq(H.get_lines(child), { "ONE", "two" })
  eq(child.lua_get([[vim.fn.getpos("'a")]]), { 0, 1, 1, 0 })
end

T["D7.5 no register is touched"] = function()
  H.set_lines(child, { "password: hunter2" })
  child.lua([[
    vim.fn.setreg('"', "unnamed")
    vim.fn.setreg("-", "smalldelete")
    vim.fn.setreg("0", "yank")
    vim.fn.setreg("a", "named")
  ]])
  local before = child.lua_get(
    [[{ vim.fn.getreg('"'), vim.fn.getreg("-"), vim.fn.getreg("0"), vim.fn.getreg("a") }]]
  )
  local res = H.run(child, "base64", H.charwise(1, 11, 1, 17))
  eq(res.ok, true)
  local after = child.lua_get(
    [[{ vim.fn.getreg('"'), vim.fn.getreg("-"), vim.fn.getreg("0"), vim.fn.getreg("a") }]]
  )
  eq(after, before)
end

-- §7.6 Failure means untouched ---------------------------------------------

T["D7.6 a failed run leaves the buffer byte-identical"] = function()
  local lines = { "alpha", "x: {nope}", "omega", "", "tail\ttab" }
  H.set_lines(child, lines)
  local before = H.get_lines(child)
  local res = H.run(child, "jq .", H.linewise(1, 5))
  eq(res.ok, false)
  eq(H.get_lines(child), before)
  eq(H.get_lines(child), lines)
end

T["D7.6 a refused run leaves the buffer byte-identical"] = function()
  local lines = { "x b", "y a", "z b" }
  H.set_lines(child, lines)
  local res = H.run(child, "sort -u", H.blockwise(1, 3, 3, 3))
  eq(res.ok, false)
  eq(H.get_lines(child), lines)
end

T["D7.6 an empty command is refused and writes nothing"] = function()
  local lines = { "alpha", "beta" }
  H.set_lines(child, lines)
  local res = H.run(child, "", H.linewise(1, 2))
  eq(res.ok, false)
  eq(type(res.msg), "string")
  eq(H.get_lines(child), lines)
end

T["D7.6 a timed-out run leaves the buffer byte-identical"] = function()
  H.setup(child, { timeout = 200 })
  local lines = { "alpha", "beta" }
  H.set_lines(child, lines)
  local res = H.run(child, "sleep 30", H.linewise(1, 2))
  eq(res.ok, false)
  eq(H.get_lines(child), lines)
end

-- §3.4 Lua API --------------------------------------------------------------

T["D3.4 run reports success as true"] = function()
  H.set_lines(child, { "one" })
  local res = H.run(child, "tr a-z A-Z", H.linewise(1, 1))
  eq(res.ok, true)
end

T["D3.4 run reports failure as false with a message"] = function()
  H.set_lines(child, { "x: {nope}" })
  local res = H.run(child, "jq .", H.linewise(1, 1))
  eq(res.ok, false)
  eq(type(res.msg), "string")
  neq(res.msg, "")
end

T["D3.4 opts.buf selects the buffer that is written"] = function()
  H.set_lines(child, { "one" })
  local target = child.lua_get([[(function()
    local b = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(b, 0, -1, true, { "two" })
    return b
  end)()]])
  local res = H.run(child, "tr a-z A-Z", H.linewise(1, 1), { buf = target })
  eq(res.ok, true)
  eq(H.get_lines(child), { "one" })
  eq(child.api.nvim_buf_get_lines(target, 0, -1, true), { "TWO" })
end

T["D3.4 run is callable with no opts"] = function()
  H.set_lines(child, { "one" })
  local res = child.lua(
    [[
      local cmd, region = ...
      local ok, msg = require("bang").run(cmd, region)
      return { ok = ok, msg = msg }
    ]],
    { "tr a-z A-Z", H.linewise(1, 1) }
  )
  eq(res.ok, true)
  eq(H.get_lines(child), { "ONE" })
end

-- §8.1 Configuration --------------------------------------------------------

T["D8.1 setup merges its options into vim.g.bang"] = function()
  H.setup(child, { timeout = 1234 })
  eq(child.lua_get("vim.g.bang.timeout"), 1234)
  eq(child.lua_get("vim.g.bang.on_error"), "keep")
end

T["D8.1 setup keeps values already in vim.g.bang"] = function()
  child.lua([[vim.g.bang = { on_error = "replace" }]])
  H.setup(child, { timeout = 1234 })
  eq(child.lua_get("vim.g.bang.on_error"), "replace")
  eq(child.lua_get("vim.g.bang.timeout"), 1234)
end

T["D8.1 setup with no options leaves the defaults in place"] = function()
  H.setup(child, {})
  eq(child.lua_get("vim.g.bang.on_error"), "keep")
  eq(child.lua_get("vim.g.bang.timeout"), 30000)
  eq(child.lua_get("vim.g.bang.expand_bang"), false)
  eq(child.lua_get("vim.g.bang.keymaps"), true)
end

T["D8.1 setup rejects an unknown on_error value"] = function()
  MiniTest.expect.error(function()
    H.setup(child, { on_error = "explode" })
  end, "on_error")
end

T["D8.1 setup rejects a non-positive timeout"] = function()
  MiniTest.expect.error(function()
    H.setup(child, { timeout = 0 })
  end, "timeout")
  MiniTest.expect.error(function()
    H.setup(child, { timeout = "soon" })
  end, "timeout")
end

T["D8.1 on_error is read at call time"] = function()
  H.setup(child, {})
  child.lua([[vim.g.bang = vim.tbl_extend("force", vim.g.bang, { on_error = "replace" })]])
  H.set_lines(child, { "one" })
  local res = H.run(child, "echo OUT; exit 3", H.linewise(1, 1))
  eq(res.ok, true)
  eq(H.get_lines(child), { "OUT" })
end

T["D8.1 timeout is read at call time"] = function()
  H.setup(child, {})
  child.lua([[vim.g.bang = vim.tbl_extend("force", vim.g.bang, { timeout = 200 })]])
  H.set_lines(child, { "one" })
  local res = H.run(child, "sleep 30", H.linewise(1, 1))
  eq(res.ok, false)
  eq(H.get_lines(child), { "one" })
end

-- §8.2 expand_bang ----------------------------------------------------------

T["D8.2 expand_bang off leaves ! literal in the command"] = function()
  H.set_lines(child, { "one", "two" })
  eq(H.run(child, "echo first", H.linewise(1, 1)).ok, true)
  local res = H.run(child, "echo 'x!y'", H.linewise(2, 2))
  eq(res.ok, true)
  eq(H.get_lines(child), { "first", "x!y" })
end

T["D8.2 expand_bang on substitutes the previous command for !"] = function()
  H.setup(child, { expand_bang = true })
  H.set_lines(child, { "one", "two" })
  eq(H.run(child, "echo first", H.linewise(1, 1)).ok, true)
  local res = H.run(child, "echo 'x!y'", H.linewise(2, 2))
  eq(res.ok, true)
  eq(H.get_lines(child), { "first", "xecho firsty" })
end

T["D8.2 a backslash-escaped ! stays a literal !"] = function()
  H.setup(child, { expand_bang = true })
  H.set_lines(child, { "one", "two" })
  eq(H.run(child, "echo first", H.linewise(1, 1)).ok, true)
  local res = H.run(child, "echo 'x\\!y'", H.linewise(2, 2))
  eq(res.ok, true)
  eq(H.get_lines(child), { "first", "x!y" })
end

T["D8.2 expand_bang with no previous command errors and runs nothing"] = function()
  H.setup(child, { expand_bang = true })
  local log = H.use_log_shell(child)
  H.set_lines(child, { "one" })
  local res = H.run(child, "echo x!y", H.linewise(1, 1))
  eq(res.ok, false)
  eq(type(res.msg), "string")
  eq(H.get_lines(child), { "one" })
  eq(H.log_shell(child, log).stdin, nil, { fail_reason = "the shell must not have been invoked" })
end

T["D8.2 a failed run does not become the previous command"] = function()
  H.setup(child, { expand_bang = true })
  H.set_lines(child, { "one", "two", "three" })
  eq(H.run(child, "echo first", H.linewise(1, 1)).ok, true)
  eq(H.run(child, "exit 9", H.linewise(2, 2)).ok, false)
  local res = H.run(child, "echo 'x!y'", H.linewise(3, 3))
  eq(res.ok, true)
  eq(H.get_lines(child)[3], "xecho firsty")
end

-- §12b Review round 1 adjudications ----------------------------------------

T["R4 (D6.3) a signal-killed command leaves the buffer untouched"] = function()
  -- `vim.system` reports `code = 0, signal = 9` for a killed child, so a naive
  -- `code == 0` test writes the partial output it managed to produce.
  H.set_lines(child, { "one", "two" })
  local res = H.run(child, "printf 'partial'; kill -9 $$", H.linewise(1, 2))
  eq(res.ok, false)
  eq(H.get_lines(child), { "one", "two" })
  eq(type(res.msg), "string")
  neq(res.msg:find("9", 1, true), nil, { fail_reason = "the message must name the signal" })
end

T["R4 (D6.3) a segfault is a failure naming its signal"] = function()
  H.set_lines(child, { "one" })
  local res = H.run(child, "kill -SEGV $$", H.linewise(1, 1))
  eq(res.ok, false)
  eq(H.get_lines(child), { "one" })
  neq(res.msg:find("11", 1, true), nil)
end

T["R4 (D6.3) replace mode does not write a signal-killed command's output"] = function()
  -- "Any non-zero signal is a failure", and D7.6 says a failure leaves the buffer
  -- byte-identical -- so, like the timeout of D6.2, this is not subject to
  -- `on_error`.
  H.setup(child, { on_error = "replace" })
  H.set_lines(child, { "one", "two" })
  local res = H.run(child, "printf 'partial'; kill -9 $$", H.linewise(1, 2))
  eq(res.ok, false)
  eq(H.get_lines(child), { "one", "two" })
end

T["R4 (D6.3) a bang does not write a signal-killed command's output"] = function()
  H.set_lines(child, { "one", "two" })
  local res = H.run(child, "printf 'partial'; kill -9 $$", H.linewise(1, 2), { bang = true })
  eq(res.ok, false)
  eq(H.get_lines(child), { "one", "two" })
end

T["R5 (D7.4) a block entirely past every line's end stays where the user put it"] = function()
  -- The left column comes from the unclamped `start.col`, so the block does not
  -- silently relocate onto the last real column.
  H.set_lines(child, { "ab", "cd" })
  local res = H.run(child, [[printf 'X\nY\n']], H.blockwise(1, 5, 2, 7))
  eq(res.ok, true)
  eq(H.get_lines(child), { "ab  X", "cd  Y" })
end

T["R6 (D6.1) a 'shell' that carries arguments is split into words"] = function()
  local log = H.use_log_shell(child, "-c", H.fixtures .. "/log_shell.sh -f")
  H.set_lines(child, { "one" })
  H.run(child, "sort", H.linewise(1, 1))
  eq(H.log_shell(child, log).argv, { "-f", "-c", "sort" })
end

T["R6 (D6.1) a backslash-escaped space in 'shell' is a literal space"] = function()
  local dir = child.lua_get("vim.fn.tempname()") .. "/with space"
  H.install_log_shell(child, dir .. "/log_shell.sh")
  local log = H.use_log_shell(child, "-c", (dir .. "/log_shell.sh"):gsub(" ", "\\ "))
  H.set_lines(child, { "one" })
  local res = H.run(child, "sort", H.linewise(1, 1))
  eq(res.ok, true, { fail_reason = "the escaped space must not split the path into two words" })
  eq(H.log_shell(child, log).argv, { "-c", "sort" })
end

T["R8 (D3.4) a nomodifiable buffer returns false for every region kind"] = function()
  local lines = { "alpha", "bravo", "charlie" }
  local regions = {
    char = H.charwise(1, 1, 1, 5),
    line = H.linewise(1, 3),
    block = H.blockwise(1, 1, 3, 3),
  }
  for kind, region in pairs(regions) do
    H.set_lines(child, lines)
    child.lua("vim.bo.modifiable = false")
    local res = H.run_pcall(child, "tr a-z A-Z", region)
    eq(res.threw, false, { fail_reason = kind .. ": run() must not raise" })
    eq(res.ok, false, { fail_reason = kind .. ": run() must report failure" })
    eq(type(res.msg), "string")
    neq(res.msg:lower():find("modifiable", 1, true), nil, { fail_reason = kind .. ": message" })
    child.lua("vim.bo.modifiable = true")
    eq(H.get_lines(child), lines, { fail_reason = kind .. ": buffer must be byte-identical" })
  end
end

T["R8 (D3.4) an invalid vim.g.bang at call time returns false naming the key"] = function()
  H.set_lines(child, { "one" })
  child.lua([[vim.g.bang = { on_error = "explode" }]])
  local res = H.run_pcall(child, "tr a-z A-Z", H.linewise(1, 1))
  eq(res.threw, false, { fail_reason = "a call-time config error is returned, not raised" })
  eq(res.ok, false)
  neq(res.msg:find("on_error", 1, true), nil)
  eq(H.get_lines(child), { "one" })
end

T["R9 (D7.6) a region starting past the last line is refused"] = function()
  local lines = { "alpha", "bravo" }
  H.set_lines(child, lines)
  local res = H.run_pcall(child, "tr a-z A-Z", H.linewise(5, 6))
  eq(res.threw, false)
  eq(res.ok, false)
  neq(res.msg:lower():find("outside", 1, true), nil)
  eq(H.get_lines(child), lines)
end

T["R9 (D7.6) a region ending past the last line is refused, not clamped"] = function()
  local lines = { "alpha", "bravo" }
  H.set_lines(child, lines)
  local res = H.run_pcall(child, "tr a-z A-Z", H.charwise(1, 1, 9, 3))
  eq(res.threw, false)
  eq(res.ok, false)
  eq(H.get_lines(child), lines, { fail_reason = "no clamping onto other lines" })
end

T["R10 (D5.4) padding is trimmed only where the block reaches the line's end"] = function()
  -- Line 1's segment stops inside the line, so its two spaces are content and
  -- stay; line 2 is padded out to the block, so its padding is trimmed away.
  H.set_lines(child, { "ab  cdef", "gh" })
  local res = H.run(child, "tr a-z A-Z", H.blockwise(1, 1, 2, 4))
  eq(res.ok, true)
  eq(H.get_lines(child), { "AB  cdef", "GH" })
end

T["R10 (D5.4) a block over tabbed lines leaves no trailing whitespace"] = function()
  child.o.tabstop = 4
  H.set_lines(child, { "a\tbcd", "e", "f\tghi" })
  local res = H.run(child, "tr a-z A-Z", H.blockwise(1, 1, 3, 5))
  eq(res.ok, true)
  eq(H.get_lines(child), { "A\tBCD", "E", "F\tGHI" })
end

T["R10 (D5.4) a blockwise run on an empty buffer leaves it empty"] = function()
  H.set_lines(child, { "" })
  local res = H.run(child, "cat", H.blockwise(1, 1, 1, 1))
  eq(res.ok, true)
  eq(H.get_lines(child), { "" }, { fail_reason = 'padding must not turn { "" } into { " " }' })
end

T["R11 (DEV-5) a bare carriage return in the output stays inside the line"] = function()
  -- bang.nvim splits on \n only. The built-in splits on a bare \r when it reads
  -- the output through a pipe ('noshelltemp', the default since 0.12) and
  -- keeps it when it goes through a temp file ('shelltemp', the 0.11 default).
  H.set_lines(child, { "zz" })
  local res = H.run(child, [[printf 'a\rb\n']], H.linewise(1, 1))
  eq(res.ok, true)
  eq(H.get_lines(child), { "a\rb" })

  child.cmd("enew!")
  H.set_lines(child, { "zz" })
  child.cmd([[silent! %!printf 'a\rb\n']])
  eq(H.get_lines(child), H.builtin_cr_lines(child), { fail_reason = "the built-in's \\r handling" })
end

T["R11 (DEV-5) a bare carriage return in the buffer stays inside the line"] = function()
  H.set_lines(child, { "a\rb" })
  local res = H.run(child, "cat", H.linewise(1, 1))
  eq(res.ok, true)
  eq(H.get_lines(child), { "a\rb" })

  child.cmd("enew!")
  H.set_lines(child, { "a\rb" })
  child.cmd("silent! %!cat")
  eq(H.get_lines(child), H.builtin_cr_lines(child), { fail_reason = "the built-in's \\r handling" })
end

T["R12 (D6.1) a doubled backslash before % reaches the shell as one backslash"] = function()
  local log = H.use_log_shell(child)
  H.set_lines(child, { "one" })
  H.run(child, [[sed 's/x/\\%/']], H.linewise(1, 1))
  eq(H.log_shell(child, log).argv, { "-c", [[sed 's/x/\%/']] })
end

T["R12 (D6.1) a single backslash before % still yields a literal %"] = function()
  local log = H.use_log_shell(child)
  H.set_lines(child, { "one" })
  H.run(child, [[sed 's/x/\%/']], H.linewise(1, 1))
  eq(H.log_shell(child, log).argv, { "-c", [[sed 's/x/%/']] })
end

T["R12 (D6.1) #<n is tokenised, not # followed by <n"] = function()
  -- `#` on its own expands to the alternate file, so a `#<n` that is not
  -- tokenised as one item leaks the alternate name plus a stray "<n".
  -- The built-in errors on `#<n` here (E684: List index out of range), so there
  -- is no parity oracle for what it expands *to*; R12 requires the tokenisation,
  -- and D6.1 lets an item that expands to nothing stand as typed.
  local name = child.lua_get("vim.fn.tempname()") .. ".txt"
  child.cmd("edit " .. name)
  child.cmd("enew")
  local buf1 = child.lua_get("vim.fn.bufnr(...)", { name })
  local log = H.use_log_shell(child)

  H.set_lines(child, { "one" })
  H.run(child, "echo #", H.linewise(1, 1))
  eq(H.log_shell(child, log).argv, { "-c", "echo " .. name }, {
    fail_reason = "# alone must expand to the alternate file",
  })

  H.set_lines(child, { "one" })
  H.run(child, "echo #<" .. buf1, H.linewise(1, 1))
  neq(H.log_shell(child, log).argv[2], "echo " .. name .. "<" .. buf1, {
    fail_reason = "#<n must not be split into # and <n",
  })
end

T["R13 (D8.1) setup rejects an unknown key by name"] = function()
  MiniTest.expect.error(function()
    H.setup(child, { on_eror = "replace" })
  end, "on_eror")
end

T["R13 (D8.1) setup accepts every documented key"] = function()
  MiniTest.expect.no_error(function()
    H.setup(child, { on_error = "replace", timeout = 5000, keymaps = false, expand_bang = true })
  end)
end

-- §12c Review round 2 adjudications ----------------------------------------

T["F11 (D6.1) a quoted 'shell' path containing a space parses as one word"] = function()
  local dir = child.lua_get("vim.fn.tempname()") .. "/with space"
  H.install_log_shell(child, dir .. "/log_shell.sh")
  local log = H.use_log_shell(child, "-c", '"' .. dir .. '/log_shell.sh"')
  H.set_lines(child, { "one" })
  local res = H.run(child, "sort", H.linewise(1, 1))
  eq(res.ok, true, { fail_reason = "the quoted path must not be split into two words" })
  eq(H.log_shell(child, log).argv, { "-c", "sort" })
end

T["F9 (D7.6) a blockwise write is all-or-nothing"] = function()
  MiniTest.skip(
    "No seam to inject a mid-write failure from outside the plugin: the N row "
      .. "writes happen inside one run() call, and nothing a test can set from the "
      .. "public contract (nomodifiable, an autocmd, a buffer attach) fires between "
      .. "them. The closest available guard is "
      .. "'D7.5 one undo restores the buffer after a blockwise run', which pins the "
      .. "single undo step but not atomicity on error."
  )
end

return T
