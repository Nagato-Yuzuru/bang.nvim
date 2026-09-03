-- Regression tests, named after the defects they pin.
--
-- The first three come from the survey of existing plugins (CONTEXT.md C3): the
-- vectors are verified (B9), the competitor behaviours are reported. Each one
-- asserts the correct result *and* the reported wrong result's absence, so the
-- test states what must never come back.
--
-- The last two pin defects of the built-in `!` that bang.nvim deliberately does
-- not reproduce (DESIGN.md DEV-1, DEV-3). Both run the built-in on a scratch
-- buffer first to show the defect is real on this Neovim, then bang.nvim on an
-- identical buffer to show the guarantee.

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

T["filter_do_charwise_trailing_newline"] = function()
  -- A charwise selection contains no newline; appending one before the command
  -- makes `base64` return aHVudGVyMgo=, which decodes to "hunter2\n" (C3.1).
  H.set_lines(child, { "password: hunter2" })
  local res = H.run(child, "base64", H.charwise(1, 11, 1, 17))
  eq(res.ok, true)
  eq(H.get_lines(child), { "password: aHVudGVyMg==" })
  neq(H.get_lines(child), { "password: aHVudGVyMgo=" })

  -- Round trip: decoding the encoded region must give the original bytes back.
  local back = H.run(child, "base64 -d", H.charwise(1, 11, 1, 22))
  eq(back.ok, true)
  eq(H.get_lines(child), { "password: hunter2" })
end

T["filter_do_multibyte_corruption"] = function()
  -- Recomputing the end column by hand truncated the last multibyte character
  -- and wrote the bare tail bytes 0x96 0x87 into the buffer (C3.2).
  H.set_lines(child, { "x 中文 y" })
  local res = H.run(child, "base64", H.charwise(1, 2, 1, 8))
  eq(res.ok, true)
  eq(H.get_lines(child), { "xIOS4reaWhw== y" })

  -- The defect wrote the bare bytes 0x96 0x87 into the buffer; base64 output is
  -- ASCII, so no byte above 0x7f may survive the write-back.
  eq(child.lua_get([[vim.fn.getline(1):find("[\128-\255]") == nil]]), true)

  -- Round trip: " 中文" comes back byte for byte.
  local back = H.run(child, "base64 -d", H.charwise(1, 2, 1, 13))
  eq(back.ok, true)
  eq(H.get_lines(child), { "x 中文 y" })
end

T["vis_off_by_one_at_both_ends"] = function()
  -- vis swallowed the character before the selection and appended a newline,
  -- yielding "password: IGh1bnRlcjIK " for the same seven characters (C3).
  H.set_lines(child, { "password: hunter2" })
  local res = H.run(child, "base64", H.charwise(1, 11, 1, 17))
  eq(res.ok, true)
  eq(H.get_lines(child), { "password: aHVudGVyMg==" })
  neq(H.get_lines(child), { "password: IGh1bnRlcjIK " })

  -- The same off-by-one showed up as seven characters turning into eight.
  H.set_lines(child, { "password: hunter2" })
  local wide = H.run(child, "sed 's/./X/g'", H.charwise(1, 11, 1, 17))
  eq(wide.ok, true)
  eq(H.get_lines(child), { "password: XXXXXXX" })
end

T["builtin_bang_overwrites_on_error"] = function()
  local start = { "x: {nope}" }

  -- The defect (CONTEXT.md B6): the built-in `!` replaces the region with jq's
  -- error message, destroying the text.
  child.cmd("enew!")
  H.set_lines(child, start)
  child.cmd("silent! %!jq .")
  local builtin = H.get_lines(child)
  neq(builtin, start, { fail_reason = "built-in ! no longer overwrites on error" })

  -- The guarantee (DEV-3): bang.nvim keeps the buffer.
  child.cmd("enew!")
  H.set_lines(child, start)
  H.type_cmd(child, "%Bang jq .")
  H.notifications(child)
  eq(H.get_lines(child), start)
  neq(H.get_lines(child), builtin)
end

T["builtin_bang_substitution"] = function()
  local start = { "zzz" }

  -- The defect (DEV-1): the built-in `!` replaces every unescaped `!` with the
  -- previous command, even inside single quotes.
  child.cmd("enew!")
  H.set_lines(child, start)
  child.cmd("silent! %!echo first")
  eq(H.get_lines(child), { "first" })
  child.cmd([[silent! %!echo 'x!y']])
  local builtin = H.get_lines(child)
  eq(builtin, { "xecho firsty" })

  -- The guarantee: with `expand_bang` off (the default), `!` is literal.
  child.cmd("enew!")
  H.set_lines(child, start)
  H.type_cmd(child, "%Bang echo first")
  eq(H.get_lines(child), { "first" })
  H.type_cmd(child, "%Bang echo 'x!y'")
  eq(H.get_lines(child), { "x!y" })
  neq(H.get_lines(child), builtin)
end

T["timeout_pipeline_leaves_child_holding_pipe"] = function()
  -- The timeout SIGKILL reaches only the shell. `sleep` and `cat` are its
  -- children: they kept stdout open, `vim.system():wait()` returned nil and
  -- run() indexed it. On Ubuntu `sh` is dash, which forks even a lone `sleep`,
  -- so every timeout test crashed there. The whole process group must die.
  H.setup(child, { timeout = 200 })
  H.set_lines(child, { "one" })
  local res = H.run(child, "sleep 31 | cat", H.linewise(1, 1))
  eq(res.ok, false)
  neq(res.msg:lower():find("timed out", 1, true), nil)
  eq(H.get_lines(child), { "one" })
  eq(
    vim.fn.system({ "pgrep", "-f", "sleep 31" }),
    "",
    { fail_reason = "the pipeline outlived the timeout" }
  )
end

return T
