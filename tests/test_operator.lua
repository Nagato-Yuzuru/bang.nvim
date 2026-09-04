-- Acceptance tests for the operator and the default keymaps.
--
-- Keys are typed into a child Neovim, so `<Plug>` resolution, counts, `.` and
-- the `:` history behave as they do for a user. `vim.ui.input` is stubbed both
-- synchronously (what native `input()` does) and deferred through
-- `vim.schedule` (what dressing.nvim and snacks.nvim do).

local H = dofile("tests/helpers.lua")

local eq, neq = MiniTest.expect.equality, MiniTest.expect.no_equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      H.setup_child(child)
    end,
    post_once = child.stop,
  },
})

-- §3.1 Operator and default keys -------------------------------------------

T["D3.1 g! with a motion filters exactly the motion's text"] = function()
  H.stub_input(child, { "base64" })
  H.set_lines(child, { "password: hunter2" })
  child.type_keys("gg", "0", "fh", "g!iw")
  eq(H.get_lines(child), { "password: aHVudGVyMg==" })
end

T["D3.1 g! with a motion keeps the region charwise"] = function()
  -- A charwise motion must not be widened to whole lines: `l` covers exactly the
  -- character under the cursor.
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "abcd" })
  child.type_keys("gg", "0", "l", "g!l")
  eq(H.get_lines(child), { "aBcd" })
end

T["D3.1 g!! filters the current line"] = function()
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "one", "two" })
  child.type_keys("gg", "g!!")
  eq(H.get_lines(child), { "ONE", "two" })
end

T["D3.1 3g!! filters three lines as one linewise region"] = function()
  H.stub_input(child, { "sort" })
  H.set_lines(child, { "c", "a", "b", "z" })
  child.type_keys("gg", "3g!!")
  eq(H.get_lines(child), { "a", "b", "c", "z" })
end

T["D3.1 g!j filters the current and the next line"] = function()
  H.stub_input(child, { "sort" })
  H.set_lines(child, { "c", "a", "z" })
  child.type_keys("gg", "g!j")
  eq(H.get_lines(child), { "a", "c", "z" })
end

T["D3.1 a count past the last line clamps to the buffer"] = function()
  H.stub_input(child, { "sort" })
  H.set_lines(child, { "c", "a" })
  child.type_keys("gg", "9g!!")
  eq(H.get_lines(child), { "a", "c" })
end

T["D3.1 Visual g! on a charwise selection filters the selection"] = function()
  H.stub_input(child, { "base64" })
  H.set_lines(child, { "password: hunter2" })
  child.type_keys("gg", "0", "fh", "v", "$", "g!")
  eq(H.get_lines(child), { "password: aHVudGVyMg==" })
end

T["D3.1 Visual g! on a linewise selection filters whole lines"] = function()
  H.stub_input(child, { "sort" })
  H.set_lines(child, { "c", "a", "b", "z" })
  child.type_keys("gg", "V", "2j", "g!")
  eq(H.get_lines(child), { "a", "b", "c", "z" })
end

T["D3.1 Visual g! on a blockwise selection filters one column"] = function()
  H.stub_input(child, { "sort" })
  H.set_lines(child, { "1 c", "2 a", "3 b" })
  child.type_keys("gg", "0", "2l", "<C-v>", "2j", "g!")
  eq(H.get_lines(child), { "1 a", "2 b", "3 c" })
end

T["D5.3 Visual g! on a CTRL-V $ block extends to each line's end"] = function()
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "abcdef", "ab", "abcd" })
  child.type_keys("gg", "0", "l", "<C-v>", "2j", "$", "g!")
  eq(H.get_lines(child), { "aBCDEF", "aB", "aBCD" })
end

T["D5.3 a rectangular block is not treated as ragged"] = function()
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "abcdef", "abcdef" })
  child.type_keys("gg", "0", "l", "<C-v>", "j", "l", "g!")
  eq(H.get_lines(child), { "aBCdef", "aBCdef" })
end

T["D3.1 the command text never reaches the buffer"] = function()
  -- The prototype fed the command line with `nvim_feedkeys` and leaked
  -- "base64" into the text (CONTEXT.md C2). `vim.ui.input` must not.
  H.stub_input(child, { "base64" })
  H.set_lines(child, { "password: hunter2", "second line" })
  child.type_keys("gg", "0", "fh", "g!iw")
  eq(H.get_lines(child), { "password: aHVudGVyMg==", "second line" })
end

-- §3.1 Rebinding ------------------------------------------------------------

T["D3.1 the default keys g! and g!! are mapped on load"] = function()
  eq(child.lua_get([[vim.tbl_isempty(vim.fn.maparg("g!", "n", false, true))]]), false)
  eq(child.lua_get([[vim.tbl_isempty(vim.fn.maparg("g!", "x", false, true))]]), false)
  eq(child.lua_get([[vim.tbl_isempty(vim.fn.maparg("g!!", "n", false, true))]]), false)
end

T["D3.1 a noremap user key bound to <Plug>(bang-operator) still fires"] = function()
  H.stub_input(child, { "tr a-z A-Z" })
  child.lua([[vim.keymap.set("n", "<Space>f", "<Plug>(bang-operator)", { noremap = true })]])
  H.set_lines(child, { "one", "two" })
  child.type_keys("gg", "<Space>f", "j")
  eq(H.get_lines(child), { "ONE", "TWO" })
end

T["D3.1 a count passes through a user key bound to <Plug>(bang-line)"] = function()
  H.stub_input(child, { "sort" })
  child.lua([[vim.keymap.set("n", "<Space>ff", "<Plug>(bang-line)", { noremap = true })]])
  H.set_lines(child, { "c", "a", "b", "z" })
  child.type_keys("gg", "3<Space>ff")
  eq(H.get_lines(child), { "a", "b", "c", "z" })
end

T["D8.1 keymaps = false at load registers no default keys"] = function()
  H.setup_child(child, { config = { keymaps = false } })
  eq(child.lua_get([[vim.tbl_isempty(vim.fn.maparg("g!", "n", false, true))]]), true)
  eq(child.lua_get([[vim.tbl_isempty(vim.fn.maparg("g!!", "n", false, true))]]), true)
  eq(child.lua_get([[vim.tbl_isempty(vim.fn.maparg("g!", "x", false, true))]]), true)
  -- The <Plug> mappings stay, so a user can bind their own keys.
  eq(
    child.lua_get([[vim.tbl_isempty(vim.fn.maparg("<Plug>(bang-operator)", "n", false, true))]]),
    false
  )
end

T["D8.1 keymaps = false at setup time deletes the default keys"] = function()
  eq(child.lua_get([[vim.tbl_isempty(vim.fn.maparg("g!", "n", false, true))]]), false)
  H.setup(child, { keymaps = false })
  eq(child.lua_get([[vim.tbl_isempty(vim.fn.maparg("g!", "n", false, true))]]), true)
  eq(child.lua_get([[vim.tbl_isempty(vim.fn.maparg("g!!", "n", false, true))]]), true)
  eq(child.lua_get([[vim.tbl_isempty(vim.fn.maparg("g!", "x", false, true))]]), true)
end

-- §3.2 Repeat ---------------------------------------------------------------

T["D3.2 . repeats the operator with the same command and no prompt"] = function()
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "one two", "three four" })
  child.type_keys("gg", "0", "g!iw")
  eq(H.prompt_count(child), 1)
  child.type_keys("j", "0", ".")
  eq(H.prompt_count(child), 1, { fail_reason = "`.` must not prompt again" })
  eq(H.get_lines(child), { "ONE two", "THREE four" })
end

T["D3.2 . is unaffected by an intervening :Bang"] = function()
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "one two", "aaa", "three four" })
  child.type_keys("gg", "0", "g!iw")
  H.type_cmd(child, "2Bang tr a-z Z")
  eq(H.get_lines(child)[2], "ZZZ")
  child.type_keys("3G", "0", ".")
  eq(H.get_lines(child), { "ONE two", "ZZZ", "THREE four" })
  eq(H.prompt_count(child), 1)
end

T["D3.2 a repeat after a cancelled prompt still uses the last run command"] = function()
  H.stub_input(child, { "tr a-z A-Z", false })
  H.set_lines(child, { "one two", "three four" })
  child.type_keys("gg", "0", "g!iw")
  child.type_keys("j", "0", "g!iw")
  eq(H.prompt_count(child), 2)
  eq(H.get_lines(child), { "ONE two", "three four" })
  child.type_keys("0", ".")
  eq(H.prompt_count(child), 2)
  eq(H.get_lines(child), { "ONE two", "THREE four" })
end

T["D3.2 . repeats a blockwise Visual g! on the block under the cursor"] = function()
  -- Vim's redo rebuilds the block at the cursor and updates `'[`/`']`, not
  -- `'<`/`'>`. `rev` is not idempotent, so a repeat that lands on the old block
  -- shows up there as a second reversal.
  H.stub_input(child, { "rev" })
  H.set_lines(child, { "abcdef", "abcdef", "", "abcdef", "abcdef" })
  child.type_keys("gg", "0", "l", "<C-v>", "j", "l", "g!")
  eq(H.get_lines(child), { "acbdef", "acbdef", "", "abcdef", "abcdef" })
  child.type_keys("4G", "0", "l", ".")
  eq(H.prompt_count(child), 1, { fail_reason = "`.` must not prompt again" })
  eq(H.get_lines(child), { "acbdef", "acbdef", "", "acbdef", "acbdef" })
end

T["D3.2 . repeats a CTRL-V $ block to each line's end"] = function()
  -- On a redo the opfunc cannot read `$` back: curswant is a column again and
  -- `']` is clamped to the last line, so the shape has to be remembered.
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "abcdefgh", "abc", "", "abcdefgh", "abc" })
  child.type_keys("gg", "0", "<C-v>", "j", "$", "g!")
  eq(H.get_lines(child), { "ABCDEFGH", "ABC", "", "abcdefgh", "abc" })
  child.type_keys("4G", "0", ".")
  eq(H.get_lines(child), { "ABCDEFGH", "ABC", "", "ABCDEFGH", "ABC" })
end

T["D3.2 . repeats a block onto a shorter far line with its full width"] = function()
  -- Boundary: `']` sits at the far line's end, which is narrower than the block.
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "abcdef", "abcdef", "", "abcdef", "ab" })
  child.type_keys("gg", "0", "l", "<C-v>", "j", "2l", "g!")
  eq(H.get_lines(child), { "aBCDef", "aBCDef", "", "abcdef", "ab" })
  child.type_keys("4G", "0", "l", ".")
  eq(H.get_lines(child), { "aBCDef", "aBCDef", "", "aBCDef", "aB" })
end

-- §4 Prompt flow ------------------------------------------------------------

T["D3.2 . repeats the command of a failed run, not an older one"] = function()
  -- Like Vim's redo buffer, the command is remembered whether or not the run
  -- succeeded: `.` must not silently reach back past the failure.
  H.stub_input(child, { "tr a-z A-Z", "jq ." })
  H.set_lines(child, { "one", "x: {nope}", "three" })
  child.type_keys("gg", "g!!")
  eq(H.get_lines(child), { "ONE", "x: {nope}", "three" })
  child.type_keys("j", "g!!")
  eq(H.prompt_count(child), 2)
  eq(#H.notifications(child), 1)

  child.type_keys("j", ".")
  eq(H.prompt_count(child), 2, { fail_reason = "`.` must not prompt again" })
  eq(
    H.get_lines(child),
    { "ONE", "x: {nope}", "three" },
    { fail_reason = "`.` must repeat `jq .`, which fails, not the older `tr a-z A-Z`" }
  )
  eq(#H.notifications(child), 2, { fail_reason = "the repeated failure must be reported too" })
end

T["D4.1 the prompt is ! with shellcmdline completion and no default"] = function()
  H.stub_input(child, { "cat" })
  H.set_lines(child, { "one" })
  child.type_keys("gg", "g!!")
  local prompts = H.prompts(child)
  eq(#prompts, 1)
  eq(prompts[1].prompt, "!")
  eq(prompts[1].completion, "shellcmdline")
  eq(prompts[1].default, nil)
end

T["D4.2 cancelling the prompt changes nothing"] = function()
  H.stub_input(child, { false })
  H.set_lines(child, { "one", "two" })
  local before = H.get_lines(child)
  local hist_before = H.cmd_history(child)
  child.type_keys("gg", "g!!")
  eq(H.get_lines(child), before)
  eq(H.cmd_history(child), hist_before)
end

T["D4.2 an empty command changes nothing"] = function()
  H.stub_input(child, { "" })
  H.set_lines(child, { "one", "two" })
  local before = H.get_lines(child)
  local hist_before = H.cmd_history(child)
  child.type_keys("gg", "g!!")
  eq(H.get_lines(child), before)
  eq(H.cmd_history(child), hist_before)
end

T["D4.2 a cancelled prompt leaves the repeat state alone"] = function()
  H.stub_input(child, { "tr a-z A-Z", false })
  H.set_lines(child, { "one", "two", "three" })
  child.type_keys("gg", "g!!")
  child.type_keys("j", "g!!")
  eq(H.get_lines(child), { "ONE", "two", "three" })
  child.type_keys("j", ".")
  eq(H.get_lines(child), { "ONE", "two", "THREE" })
end

T["D4.3 a deferred prompt still filters the captured region"] = function()
  H.stub_input(child, { "tr a-z A-Z" }, { defer = true })
  H.set_lines(child, { "one", "two" })
  child.type_keys("gg", "g!!")
  child.lua("vim.wait(100)")
  eq(H.get_lines(child), { "ONE", "two" })
end

T["D4.3 an edit between prompt and confirm aborts the write"] = function()
  H.stub_input(child, { "tr a-z A-Z" }, {
    defer = true,
    between = [[vim.api.nvim_buf_set_lines(0, 0, -1, true, { "edited", "two" })]],
  })
  H.set_lines(child, { "one", "two" })
  child.type_keys("gg", "g!!")
  child.lua("vim.wait(100)")
  eq(H.get_lines(child), { "edited", "two" })
  neq(#H.notifications(child), 0, { fail_reason = "the abort must be reported" })
end

T["D4.3 a deferred prompt on a wiped buffer writes nothing"] = function()
  H.stub_input(child, { "tr a-z A-Z" }, {
    defer = true,
    between = [[
      _G.victim = vim.api.nvim_get_current_buf()
      vim.cmd("enew!")
      vim.api.nvim_buf_delete(_G.victim, { force = true })
    ]],
  })
  H.set_lines(child, { "one", "two" })
  child.type_keys("gg", "g!!")
  child.lua("vim.wait(100)")
  eq(child.lua_get("vim.api.nvim_buf_is_valid(_G.victim)"), false)
  neq(#H.notifications(child), 0, { fail_reason = "the abort must be reported" })
end

-- §6.5 Notifications must not abort the operator ---------------------------

T["D6.5 an ERROR notification does not abort the enclosing normal command"] = function()
  -- CONTEXT.md B10: a synchronous ERROR notify inside an opfunc aborts the
  -- enclosing `normal!`. Routing it through `vim.schedule` is what prevents it.
  H.stub_input(child, { "jq ." })
  H.set_lines(child, { "x: {nope}", "second" })
  child.type_keys("gg")
  local before = H.get_lines(child)
  local res = child.lua_get([[{ pcall(vim.cmd, "normal g!!") }]])
  eq(res[1], true)
  eq(H.get_lines(child), before)
  local notes = H.notifications(child)
  eq(#notes, 1)
  eq(notes[1].level, 4)
end

T["D7.6 a failing operator run leaves the buffer byte-identical"] = function()
  H.stub_input(child, { "jq ." })
  H.set_lines(child, { "alpha", "x: {nope}", "omega" })
  local before = H.get_lines(child)
  child.type_keys("2G", "g!!")
  eq(H.get_lines(child), before)
end

T["D7.5 gv after a Visual g! reselects the filtered lines"] = function()
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "a", "b", "c", "d" })
  child.type_keys("gg", "V", "2j", "g!")
  eq(H.get_lines(child), { "A", "B", "C", "d" })
  child.type_keys("gv")
  eq(
    child.lua_get([[{ vim.fn.mode(), vim.fn.getpos("v")[2], vim.fn.getpos(".")[2] }]]),
    { "V", 1, 3 }
  )
  child.type_keys("<Esc>")
end

T["D7.5 gv after a blockwise g! reselects the block"] = function()
  H.stub_input(child, { "sort" })
  H.set_lines(child, { "1 c", "2 a", "3 b" })
  child.type_keys("gg", "0", "2l", "<C-v>", "2j", "g!")
  eq(H.get_lines(child), { "1 a", "2 b", "3 c" })
  child.type_keys("gv")
  eq(
    child.lua_get([[{ vim.fn.mode(), vim.fn.getpos("v"), vim.fn.getpos(".") }]]),
    { "\22", { 0, 1, 3, 0 }, { 0, 3, 3, 0 } }
  )
  child.type_keys("<Esc>")
end

-- §9.2 History from the operator paths --------------------------------------

T["D9.2 a successful operator run records Bang <cmd>"] = function()
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "one" })
  child.type_keys("gg", "g!!")
  local hist = H.cmd_history(child)
  eq(hist[#hist], "Bang tr a-z A-Z")
end

T["D9.2 a successful Visual run records '<,'>Bang <cmd>"] = function()
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "one", "two" })
  child.type_keys("gg", "V", "j", "g!")
  local hist = H.cmd_history(child)
  eq(hist[#hist], "'<,'>Bang tr a-z A-Z")
end

T["D9.2 a cancelled prompt records nothing"] = function()
  H.stub_input(child, { false })
  H.set_lines(child, { "one" })
  local before = H.cmd_history(child)
  child.type_keys("gg", "g!!")
  eq(H.cmd_history(child), before)
end

T["D9.2 a failed run records nothing"] = function()
  H.stub_input(child, { "jq ." })
  H.set_lines(child, { "x: {nope}" })
  local before = H.cmd_history(child)
  child.type_keys("gg", "g!!")
  H.notifications(child)
  eq(H.cmd_history(child), before)
end

-- §12b Review round 1 adjudications ----------------------------------------

T["R3 (D3.2) . after an aborted g!<Esc> reuses the last command"] = function()
  -- The fresh-invocation flag survives an aborted operator unless something
  -- clears it, and a stale flag makes the next `.` prompt.
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "one", "two" })
  child.type_keys("gg", "g!!")
  eq(H.get_lines(child), { "ONE", "two" })
  child.type_keys("g!", "<Esc>")
  child.type_keys("j", ".")
  eq(H.prompt_count(child), 1, { fail_reason = "the aborted operator must not make `.` prompt" })
  eq(H.get_lines(child), { "ONE", "TWO" })
end

T["R3 (D3.2) . after an aborted g!i<Esc> reuses the last command"] = function()
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "one", "two" })
  child.type_keys("gg", "g!!")
  child.type_keys("g!i", "<Esc>")
  child.type_keys("j", ".")
  eq(H.prompt_count(child), 1, { fail_reason = "the aborted operator must not make `.` prompt" })
  eq(H.get_lines(child), { "ONE", "TWO" })
end

T["R7 (D8.1) a user mapping on g! is left alone at load"] = function()
  H.setup_child(child, {
    pre_plugin = [[vim.keymap.set("n", "g!", "<Nop>", { desc = "user mapping" })]],
  })
  eq((H.global_map(child, "n", "g!") or {}).desc, "user mapping")
end

T["R7 (D8.1) setup does not clobber a user mapping on g!"] = function()
  child.lua([[vim.keymap.set("n", "g!", "<Nop>", { desc = "user mapping" })]])
  H.setup(child, {})
  eq((H.global_map(child, "n", "g!") or {}).desc, "user mapping")
  child.lua([[vim.keymap.set("x", "g!", "<Nop>", { desc = "user visual" })]])
  H.setup(child, { timeout = 5000 })
  eq((H.global_map(child, "x", "g!") or {}).desc, "user visual")
end

T["R7 (D8.1) keymaps = false deletes our global g! but not a buffer-local one"] = function()
  child.lua([[vim.keymap.set("n", "g!", "<Nop>", { buffer = 0, desc = "buffer local" })]])
  H.setup(child, { keymaps = false })
  eq(H.global_map(child, "n", "g!"), nil, { fail_reason = "our global mapping must still go" })
  eq((H.buffer_map(child, "n", "g!") or {}).desc, "buffer local")
end

T["R7 (D8.1) keymaps = false leaves a user's global g! alone"] = function()
  child.lua([[vim.keymap.set("n", "g!", "<Nop>", { desc = "user mapping" })]])
  H.setup(child, { keymaps = false })
  eq((H.global_map(child, "n", "g!") or {}).desc, "user mapping")
end

T["R17 (D3.2) . in another buffer reuses the expanded command"] = function()
  -- `repeat_cmd` stores the command after expansion, as Vim's redo buffer does,
  -- so `%` keeps meaning the buffer the operator originally ran in.
  child.o.hidden = true
  local alpha = child.lua_get("vim.fn.tempname()") .. "-alpha.txt"
  local beta = child.lua_get("vim.fn.tempname()") .. "-beta.txt"
  H.stub_input(child, { "echo %" })

  child.cmd("edit " .. alpha)
  H.set_lines(child, { "one" })
  child.type_keys("gg", "g!!")
  eq(H.get_lines(child), { alpha })

  child.cmd("edit " .. beta)
  H.set_lines(child, { "one" })
  child.type_keys("gg", ".")
  eq(H.prompt_count(child), 1)
  eq(H.get_lines(child), { alpha }, { fail_reason = "`.` must not re-expand % in the new buffer" })
end

-- §12c Review round 2 adjudications ----------------------------------------

T["F1 (D3.2) a forced charwise motion prompts for a new command"] = function()
  -- `g!v}` leaves Operator-pending for `no:nov` before the opfunc runs. A clear
  -- autocmd matching that transition wiped the fresh-invocation flag, so the
  -- operator silently repeated the previous command over the motion.
  -- No empty line in the buffer, so this stays a pure F1 signal: a region ending
  -- on an empty line is F3's case and belongs to the fuzz.
  H.stub_input(child, { "tr a-z A-Z", "tr a-z X" })
  H.set_lines(child, { "seed", "two", "three" })
  child.type_keys("gg", "g!!")
  eq(H.get_lines(child), { "SEED", "two", "three" })

  child.type_keys("2G", "0", "g!", "v", "}")
  eq(H.prompt_count(child), 2, { fail_reason = "a forced motion is a fresh invocation" })
  eq(H.get_lines(child), { "SEED", "XXX", "XXXXe" })
end

T["F1 (D3.2) a forced linewise motion prompts for a new command"] = function()
  H.stub_input(child, { "tr a-z A-Z", "tr a-z X" })
  H.set_lines(child, { "seed", "aa", "bb", "cc" })
  child.type_keys("gg", "g!!")
  child.type_keys("2G", "0", "g!", "V", "j")
  eq(H.prompt_count(child), 2)
  eq(H.get_lines(child), { "SEED", "XX", "XX", "cc" })
end

T["F1 (D3.2) a forced blockwise motion prompts for a new command"] = function()
  H.stub_input(child, { "tr a-z A-Z", "tr a-z X" })
  H.set_lines(child, { "seed", "ab", "cd" })
  child.type_keys("gg", "g!!")
  child.type_keys("2G", "0", "g!", "<C-v>", "j")
  eq(H.prompt_count(child), 2)
  eq(H.get_lines(child), { "SEED", "Xb", "Xd" })
end

T["F1 (D3.2) a search motion prompts for a new command"] = function()
  -- `g!/pat<CR>` passes through `no:c` on its way to the opfunc.
  H.stub_input(child, { "tr a-z A-Z", "tr a-z X" })
  H.set_lines(child, { "seed", "aaa bbb" })
  child.type_keys("gg", "g!!")
  child.type_keys("2G", "0", "g!", "/bbb", "<CR>")
  eq(H.prompt_count(child), 2, { fail_reason = "a search motion is a fresh invocation" })
  eq(H.get_lines(child), { "SEED", "XXX bbb" })
end

T["F1 (R3) an aborted operator still repeats silently"] = function()
  -- Regression guard: narrowing the clear autocmd must not reopen R3.
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "one", "two", "three" })
  child.type_keys("gg", "g!!")
  child.type_keys("g!", "<Esc>")
  child.type_keys("j", ".")
  eq(H.prompt_count(child), 1)
  child.type_keys("g!i", "<Esc>")
  child.type_keys("j", ".")
  eq(H.prompt_count(child), 1)
  eq(H.get_lines(child), { "ONE", "TWO", "THREE" })
end

T["F5 (D3.2) . reuses the raw command instead of expanding it twice"] = function()
  -- `\%` expands to a literal `%`. If the repeat stores the *expanded* command
  -- the engine expands it again and `%` becomes the buffer's name.
  local name = child.lua_get("vim.fn.tempname()") .. "-plain.txt"
  child.cmd("edit " .. name)
  H.stub_input(child, { [[sed 's/a/\%/']] })
  H.set_lines(child, { "aaa", "aaa" })
  child.type_keys("gg", "0", "g!iw")
  eq(H.get_lines(child), { "%aa", "aaa" })

  child.type_keys("j", "0", ".")
  eq(H.prompt_count(child), 1)
  eq(H.get_lines(child), { "%aa", "%aa" }, {
    fail_reason = "`.` must run the same command, not re-expand its result",
  })
end

T["F12 a block entered with i_CTRL-O is taken as a block or refused"] = function()
  -- The owner's call between "accept as blockwise" and "refuse with a message"
  -- is open; what §12c settles is that it must not write the wrong region.
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "abcd", "efgh" })
  child.type_keys("gg", "0", "i", "<C-o>", "<C-v>", "jl", "g!")
  child.type_keys("<Esc>")
  local lines = H.get_lines(child)
  local as_block = vim.deep_equal(lines, { "ABcd", "EFgh" })
  local refused = vim.deep_equal(lines, { "abcd", "efgh" }) and #H.notifications(child) > 0
  eq(as_block or refused, true, {
    fail_reason = "wrote " .. vim.inspect(lines) .. "; must be the block or a reported refusal",
  })
end

-- §12e Issue #8 rulings -----------------------------------------------------

T["#8 v$ filters to the last character and keeps the line break"] = function()
  -- Vim's own oracles disagree -- `v$d` and `v$c` join the lines, `v$y` yanks
  -- the break, `v$gU` leaves it -- and the ruling follows `gU`.
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "abc", "def" })
  child.type_keys("gg", "0", "v", "$", "g!")
  eq(H.get_lines(child), { "ABC", "def" })
end

T["#8 a block edge inside a <Tab> sends the whole tab"] = function()
  -- The block's left edge is cell 4, inside the tab that spans cells 2 to 8:
  -- the tab belongs to the block whole, as `gU` treats it, and the "a" before
  -- it is left alone. Splitting it into spaces, as `c` and `d` do, would change
  -- bytes outside the region.
  child.o.tabstop = 8
  H.stub_input(child, { "tr '\\t' X" })
  H.set_lines(child, { "a\tbcd", "efghijklmno" })
  child.type_keys("2G", "0", "3l", "<C-v>", "7l", "k", "g!")
  eq(H.get_lines(child), { "aXbcd", "efghijklmno" })
end

T["#8 g! on an exclusive block leaves out the cursor column"] = function()
  -- Oracle: with 'selection' = "exclusive", `l<C-v>ld` on "1234" gives "134".
  child.o.selection = "exclusive"
  H.stub_input(child, { "tr 0-9 a-j" })
  H.set_lines(child, { "1234", "5678" })
  child.type_keys("gg", "0", "l", "<C-v>", "jl", "g!")
  eq(H.get_lines(child), { "1c34", "5g78" })
end

T["#8 an exclusive block keeps a wide character on its right edge whole"] = function()
  -- Vim leaves the later corner's character out only when the block stays at
  -- least as wide as the earlier corner's character without it. Every result
  -- here is what `gU` gives on the same keys.
  child.o.selection = "exclusive"
  H.stub_input(child, { "tr a-z A-Z" })

  -- The cursor lands on "あ" (cells 1-2) below "a" (cell 1): too narrow to
  -- exclude, so the block is cells 1-2.
  H.set_lines(child, { "ab", "あ" })
  child.type_keys("gg", "0", "<C-v>", "j", "g!")
  eq(H.get_lines(child), { "AB", "あ" })

  -- The cursor lands on "あ" (cells 3-4) below "c" (cell 3): same, cells 3-4.
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "abcd", "abあ" })
  child.type_keys("gg", "0", "2l", "<C-v>", "j", "g!")
  eq(H.get_lines(child), { "abCD", "abあ" })
end

T["#8 an exclusive block keeps a <Tab> on its right edge whole"] = function()
  child.o.tabstop = 8
  child.o.selection = "exclusive"
  H.stub_input(child, { "tr a-z A-Z" })
  -- The cursor lands inside the tab (cells 3-8) below "c" (cell 3): the block
  -- is cells 3-8, so line 1 loses its case on "cd" and the tab stays.
  H.set_lines(child, { "abcd", "ab\tz" })
  child.type_keys("gg", "0", "2l", "<C-v>", "j", "g!")
  eq(H.get_lines(child), { "abCD", "ab\tz" })
end

T["#8 an exclusive block widened leftwards by a <Tab> matches gU"] = function()
  -- The later corner sits inside a tab that starts at cell 1, so it drags the
  -- left edge out to cell 1 and holds the right edge at cell 8: `gU` on the
  -- same keys gives exactly this.
  child.o.tabstop = 8
  child.o.selection = "exclusive"
  H.stub_input(child, { "tr a-z A-Z" })
  H.set_lines(child, { "aあqあzqz", "bazq", "\tあ b" })
  child.type_keys("gg", "0", "2l", "<C-v>", "2j", "g!")
  eq(H.get_lines(child), { "AあQあZQz", "BAZQ", "\tあ b" })
end

return T
