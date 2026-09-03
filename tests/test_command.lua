-- Acceptance tests for `:Bang[!]`, the history picker and `history()`.
--
-- `:Bang` tells a Visual selection from a line range by reading
-- `histget(":", -1)` (DESIGN.md §3.3), and only *typed* commands reach the
-- history, so every region-resolution case types the command with
-- `H.type_cmd()` rather than calling `vim.cmd()`.

local H = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      H.setup_child(child)
    end,
    post_once = child.stop,
  },
})

-- §3.3 Region resolution ----------------------------------------------------

T["D3.3 a typed line range runs linewise on that range"] = function()
  H.set_lines(child, { "z", "c", "a", "b", "y" })
  H.type_cmd(child, "2,4Bang sort")
  eq(H.get_lines(child), { "z", "a", "b", "c", "y" })
end

T["D3.3 no range runs on the current line"] = function()
  H.set_lines(child, { "one", "two", "three" })
  child.type_keys("2G")
  H.type_cmd(child, "Bang tr a-z A-Z")
  eq(H.get_lines(child), { "one", "TWO", "three" })
end

T["D3.3 % runs on the whole buffer"] = function()
  H.set_lines(child, { "c", "a", "b" })
  H.type_cmd(child, "%Bang sort")
  eq(H.get_lines(child), { "a", "b", "c" })
end

T["DEV-2 :'<,'>Bang from a charwise selection acts on the selection"] = function()
  H.set_lines(child, { "password: hunter2" })
  child.type_keys("gg", "0", "fh", "v", "$", "<Esc>")
  H.type_cmd(child, "'<,'>Bang base64")
  eq(H.get_lines(child), { "password: aHVudGVyMg==" })
end

T["DEV-2 :'<,'>Bang from a blockwise selection acts on the block"] = function()
  H.set_lines(child, { "1 c", "2 a", "3 b" })
  child.type_keys("gg", "0", "2l", "<C-v>", "2j", "<Esc>")
  H.type_cmd(child, "'<,'>Bang sort")
  eq(H.get_lines(child), { "1 a", "2 b", "3 c" })
end

T["D5.3 :'<,'>Bang on a CTRL-V $ block extends to each line's end"] = function()
  -- `curswant` does not survive into the command callback; the tell-tale is a
  -- '> column past the end of its line.
  H.set_lines(child, { "abcdef", "ab", "abcd" })
  child.type_keys("gg", "0", "l", "<C-v>", "2j", "$", "<Esc>")
  H.type_cmd(child, "'<,'>Bang tr a-z A-Z")
  eq(H.get_lines(child), { "aBCDEF", "aB", "aBCD" })
end

T["D5.3 :'<,'>Bang on a rectangular block stays rectangular"] = function()
  H.set_lines(child, { "abcdef", "abcdef" })
  child.type_keys("gg", "0", "l", "<C-v>", "j", "l", "<Esc>")
  H.type_cmd(child, "'<,'>Bang tr a-z A-Z")
  eq(H.get_lines(child), { "aBCdef", "aBCdef" })
end

T["D3.3 :'<,'>Bang from a linewise selection runs linewise"] = function()
  H.set_lines(child, { "c", "a", "b" })
  child.type_keys("gg", "V", "2j", "<Esc>")
  H.type_cmd(child, "'<,'>Bang sort")
  eq(H.get_lines(child), { "a", "b", "c" })
end

T["D3.3 a typed numeric range is linewise even when stale Visual marks coincide"] = function()
  -- The false-positive case: '< and '> point inside line 1, but the user typed
  -- `1,1Bang`, so the whole line must be filtered.
  H.set_lines(child, { "password: hunter2" })
  child.type_keys("gg", "0", "fh", "v", "$", "<Esc>")
  H.type_cmd(child, "1,1Bang base64")
  eq(H.get_lines(child), { "cGFzc3dvcmQ6IGh1bnRlcjIK" })
end

T["R2 (D3.3) :'<,'>Bang with 'history' = 0 still acts on the selection"] = function()
  -- With no history entry to consult, the marks-and-lines guard decides on its
  -- own: this used to degrade to linewise.
  child.o.history = 0
  H.set_lines(child, { "password: hunter2" })
  child.type_keys("gg", "0", "fh", "v", "$", "<Esc>")
  H.type_cmd(child, "'<,'>Bang base64")
  eq(H.get_lines(child), { "password: aHVudGVyMg==" })
end

T["D3.3 whitespace inside the '<,'> range is still recognised"] = function()
  H.set_lines(child, { "password: hunter2" })
  child.type_keys("gg", "0", "fh", "v", "$", "<Esc>")
  H.type_cmd(child, "  '< , '> Bang base64")
  eq(H.get_lines(child), { "password: aHVudGVyMg==" })
end

-- §3.3 / §6 The bang --------------------------------------------------------

T["D6.4 :Bang! writes the merged output despite a non-zero exit"] = function()
  H.set_lines(child, { "one" })
  H.type_cmd(child, "Bang! echo OUT; echo ERR >&2; exit 3")
  eq(H.get_lines(child), { "OUT", "ERR" })
end

T["D6.3 :Bang without the bang keeps the buffer on a non-zero exit"] = function()
  H.set_lines(child, { "x: {nope}" })
  local before = H.get_lines(child)
  H.type_cmd(child, "Bang jq .")
  H.notifications(child)
  eq(H.get_lines(child), before)
end

T["D6.4 :Bang! overrides on_error for that call only"] = function()
  H.setup(child, { on_error = "keep" })
  H.set_lines(child, { "one", "two" })
  H.type_cmd(child, "1Bang! echo OUT; exit 3")
  eq(H.get_lines(child), { "OUT", "two" })
  H.type_cmd(child, "2Bang echo OUT; exit 3")
  H.notifications(child)
  eq(H.get_lines(child), { "OUT", "two" })
  eq(child.lua_get("vim.g.bang.on_error"), "keep")
end

T["D3.3 :Bang completes shell commands on its argument"] = function()
  eq(child.lua_get([[vim.fn.getcompletion("Bang base6", "cmdline")]]), { "base64" })
end

-- §9.4 History picker -------------------------------------------------------

T["D9.4 :Bang with no arguments opens the history picker"] = function()
  H.histadd(child, { "Bang sort", "Bang tr a-z A-Z" })
  H.stub_select(child, "sort")
  H.set_lines(child, { "c", "a", "b" })
  H.type_cmd(child, "1,3Bang")
  local selects = H.selects(child)
  eq(#selects, 1)
  eq(selects[1].items, { "tr a-z A-Z", "sort" })
  eq(selects[1].opts.prompt, "Bang history")
  eq(H.get_lines(child), { "a", "b", "c" })
end

T["D9.4 the picked command runs on the region the :Bang named"] = function()
  H.histadd(child, { "Bang base64" })
  H.stub_select(child, "base64")
  H.set_lines(child, { "password: hunter2" })
  child.type_keys("gg", "0", "fh", "v", "$", "<Esc>")
  H.type_cmd(child, "'<,'>Bang")
  eq(H.get_lines(child), { "password: aHVudGVyMg==" })
end

T["D9.4 the picked command inherits the bang"] = function()
  H.histadd(child, { "Bang echo OUT; exit 3" })
  H.stub_select(child, "echo OUT; exit 3")
  H.set_lines(child, { "one" })
  H.type_cmd(child, "Bang!")
  eq(H.get_lines(child), { "OUT" })
end

T["D9.4 dismissing the picker changes nothing"] = function()
  H.histadd(child, { "Bang sort" })
  H.stub_select(child, false)
  H.set_lines(child, { "c", "a", "b" })
  H.type_cmd(child, "1,3Bang")
  eq(H.get_lines(child), { "c", "a", "b" })
end

-- §9.2 What gets recorded ---------------------------------------------------

T["D9.2 a typed :Bang is recorded by Vim itself"] = function()
  H.set_lines(child, { "one" })
  H.type_cmd(child, "Bang tr a-z A-Z")
  local hist = H.cmd_history(child)
  eq(hist[#hist], "Bang tr a-z A-Z")
end

-- §9.1 / §9.3 history() -----------------------------------------------------

T["D9.3 history returns Bang command texts newest first"] = function()
  H.histadd(child, { "Bang sort", "Bang rev", "Bang jq ." })
  eq(H.history(child), { "jq .", "rev", "sort" })
end

T["D9.3 history accepts a range and a bang before the command name"] = function()
  -- The `'<,'>` entry only parses when the Visual marks exist, which is the case
  -- for any history entry a user could actually have typed (R14).
  H.set_lines(child, { "one", "two", "three", "four", "five" })
  child.type_keys("gg", "v", "j", "<Esc>")
  H.histadd(child, {
    "Bang sort",
    "%Bang rev",
    "1,5Bang! jq .",
    "'<,'>Bang base64",
    ".,+3Bang tr a-z A-Z",
  })
  eq(H.history(child), { "tr a-z A-Z", "base64", "jq .", "rev", "sort" })
end

T["D9.3 history deduplicates, keeping the newest position"] = function()
  H.histadd(child, { "Bang sort", "Bang rev", "%Bang! sort" })
  eq(H.history(child), { "sort", "rev" })
end

T["D9.3 history skips a bare Bang"] = function()
  H.histadd(child, { "Bang sort", "Bang", "Bang!" })
  eq(H.history(child), { "sort" })
end

T["D9.3 history ignores entries that are not :Bang"] = function()
  H.histadd(child, { "Bang sort", "Banger x", "sort", "write", "BangBang y" })
  eq(H.history(child), { "sort" })
end

T["D9.3 history is empty when nothing was recorded"] = function()
  eq(H.history(child), {})
end

T["D9.1 the : history is the only store"] = function()
  H.set_lines(child, { "one" })
  H.type_cmd(child, "Bang tr a-z A-Z")
  eq(H.history(child), { "tr a-z A-Z" })
  child.lua([[vim.fn.histdel(":")]])
  eq(H.history(child), {})
end

T["D9.1 a repeated command moves to the top instead of duplicating"] = function()
  H.histadd(child, { "Bang sort", "Bang rev" })
  eq(H.history(child), { "rev", "sort" })
  H.histadd(child, { "Bang sort" })
  eq(H.history(child), { "sort", "rev" })
end

-- §7.6 -----------------------------------------------------------------------

T["D7.6 a failing :Bang leaves the buffer byte-identical"] = function()
  local lines = { "alpha", "x: {nope}", "omega" }
  H.set_lines(child, lines)
  H.type_cmd(child, "%Bang jq .")
  H.notifications(child)
  eq(H.get_lines(child), lines)
end

T["D9.2 a failed :Bang records no history entry of its own"] = function()
  H.set_lines(child, { "x: {nope}" })
  H.type_cmd(child, "Bang jq .")
  H.notifications(child)
  -- Vim recorded the typed line, but `history()` must not gain a second copy.
  eq(H.history(child), { "jq ." })
  local hist = H.cmd_history(child)
  eq(#hist, 1)
end

-- §12b Review round 1 adjudications ----------------------------------------

T["R1 (D5.3) a rectangular block overhanging a short line keeps the tails"] = function()
  -- `'>` sits at length + 1 on the short last line exactly as it does after
  -- `CTRL-V $`, so reading it as `$` destroyed the tail of every line. The
  -- block is rectangular: only the first three columns change.
  H.set_lines(child, { "alpha  1", "bravo  2", "ch" })
  child.type_keys("gg", "0", "<C-v>", "2j", "ll", "<Esc>")
  H.type_cmd(child, "'<,'>Bang tr a-z X")
  eq(H.get_lines(child), { "XXXha  1", "XXXvo  2", "XX" })
end

T["R2 (D3.3) :'<,'>Bang from a mapping acts on the selection"] = function()
  -- A mapping puts nothing in `:` history, so the marks-and-lines guard alone
  -- has to reach the Visual reading. This used to fall back to linewise.
  child.lua([[vim.keymap.set("n", "<Space>b", ":'<,'>Bang base64<CR>", { silent = true })]])
  H.set_lines(child, { "password: hunter2" })
  child.type_keys("gg", "0", "fh", "v", "$", "<Esc>")
  child.type_keys("<Space>b")
  eq(H.get_lines(child), { "password: aHVudGVyMg==" })
end

T["R2 (D3.3) :'<,'>Bang from vim.cmd acts on the selection"] = function()
  H.set_lines(child, { "password: hunter2" })
  child.type_keys("gg", "0", "fh", "v", "$", "<Esc>")
  child.lua([[vim.cmd("'<,'>Bang base64")]])
  eq(H.get_lines(child), { "password: aHVudGVyMg==" })
end

T["R2 (D3.3) a numeric range from a mapping is linewise despite a stale history entry"] = function()
  -- The Visual `g!` leaves `'<,'>Bang tr a-z A-Z` at the top of `:` history and
  -- the marks on line 3. The mapping's `:1,2Bang sort` must not be hijacked by
  -- either.
  child.lua([[vim.keymap.set("n", "<Space>b", ":1,2Bang sort<CR>", { silent = true })]])
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "c", "a", "zz" })
  child.type_keys("3G", "0", "v", "l", "g!")
  eq(H.get_lines(child), { "c", "a", "ZZ" })
  local hist = H.cmd_history(child)
  eq(hist[#hist], "'<,'>Bang tr a-z A-Z")

  child.type_keys("<Space>b")
  eq(H.get_lines(child), { "a", "c", "ZZ" })
end

T["R14 (D9.3) history finds an entry with a mark range"] = function()
  H.set_lines(child, { "one", "two", "three", "four" })
  child.lua([[
    vim.api.nvim_buf_set_mark(0, "a", 2, 0, {})
    vim.api.nvim_buf_set_mark(0, "b", 3, 0, {})
  ]])
  H.histadd(child, { "'a,'bBang sort" })
  eq(H.history(child), { "sort" })
end

T["R14 (D9.3) history finds an entry with a pattern range"] = function()
  H.set_lines(child, { "one", "target", "three" })
  H.histadd(child, { "/target/Bang sort" })
  eq(H.history(child), { "sort" })
end

T["R14 (D9.3) history still rejects commands that only look like Bang"] = function()
  H.histadd(child, { "Bang sort", "Bangs", "norm Bang x", "Banger x", "BangBang y" })
  eq(H.history(child), { "sort" })
end

T["R14 (D9.3) history preserves the command text verbatim"] = function()
  -- Reconstructing the text from parsed argument words would collapse runs of
  -- spaces and break the command.
  H.histadd(child, { [[Bang sed 's/a  b/c/']] })
  eq(H.history(child), { [[sed 's/a  b/c/']] })
end

T["R15 (D9.4) a command run from the picker moves to the top of history"] = function()
  H.histadd(child, { "Bang sort", "Bang rev" })
  eq(H.history(child), { "rev", "sort" })
  H.stub_select(child, "sort")
  H.set_lines(child, { "c", "a", "b" })
  H.type_cmd(child, "1,3Bang")
  eq(H.get_lines(child), { "a", "b", "c" })
  eq(H.history(child), { "sort", "rev" })
end

-- §12c Review round 2 adjudications ----------------------------------------

T["F4 (D5.3) a $ block built inside :normal! reaches each line's end"] = function()
  -- `CursorMoved` does not fire inside `:normal!`, so a record kept only from
  -- cursor movement misses the `$`.
  H.set_lines(child, { "abcdef", "ab", "abcd" })
  child.lua([[
    vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("gg0l<C-v>2j$<Esc>", true, false, true))
  ]])
  H.type_cmd(child, "'<,'>Bang tr a-z A-Z")
  eq(H.get_lines(child), { "aBCDEF", "aB", "aBCD" })
end

T["F4 (D5.3) a $ block replayed from a macro reaches each line's end"] = function()
  H.set_lines(child, { "abcdef", "ab", "abcd" })
  child.lua([[
    vim.fn.setreg("q", vim.api.nvim_replace_termcodes("gg0l<C-v>2j$<Esc>", true, false, true))
  ]])
  child.type_keys("@q")
  H.type_cmd(child, "'<,'>Bang tr a-z A-Z")
  eq(H.get_lines(child), { "aBCDEF", "aB", "aBCD" })
end

T["F4 (D5.3) a rectangular block built inside :normal! stays rectangular"] = function()
  H.set_lines(child, { "alpha  1", "bravo  2", "ch" })
  child.lua([[
    vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("gg0<C-v>2jll<Esc>", true, false, true))
  ]])
  H.type_cmd(child, "'<,'>Bang tr a-z X")
  eq(H.get_lines(child), { "XXXha  1", "XXXvo  2", "XX" })
end

T["F6 (D3.3) :silent before the range does not force linewise"] = function()
  H.set_lines(child, { "password: hunter2" })
  child.type_keys("gg", "0", "fh", "v", "$", "<Esc>")
  H.type_cmd(child, "silent '<,'>Bang base64")
  eq(H.get_lines(child), { "password: aHVudGVyMg==" })
end

T["F6 (D3.3) :keepjumps before the range does not force linewise"] = function()
  H.set_lines(child, { "password: hunter2" })
  child.type_keys("gg", "0", "fh", "v", "$", "<Esc>")
  H.type_cmd(child, "keepjumps '<,'>Bang base64")
  eq(H.get_lines(child), { "password: aHVudGVyMg==" })
end

T["F6 (D3.3) :'<;'>Bang is a different range and acts linewise"] = function()
  H.set_lines(child, { "password: hunter2" })
  child.type_keys("gg", "0", "fh", "v", "$", "<Esc>")
  H.type_cmd(child, "'<;'>Bang base64")
  eq(H.get_lines(child), { "cGFzc3dvcmQ6IGh1bnRlcjIK" })
end

T["F6 (D3.3) :'<,'>+0Bang is a different range and acts linewise"] = function()
  H.set_lines(child, { "password: hunter2" })
  child.type_keys("gg", "0", "fh", "v", "$", "<Esc>")
  H.type_cmd(child, "'<,'>+0Bang base64")
  eq(H.get_lines(child), { "cGFzc3dvcmQ6IGh1bnRlcjIK" })
end

T["F10 (D9.3) a :substitute whose pattern contains Bang stays out of history()"] = function()
  H.histadd(child, {
    "Bang sort",
    "%s/Bang/x/g",
    "s/foo/Bang rev/",
    "%s#Bang#y#",
    "g/Bang/d",
  })
  eq(H.history(child), { "sort" })
end

return T
