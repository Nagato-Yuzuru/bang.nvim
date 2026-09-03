-- Test harness for bang.nvim (mini.test).
--
-- Run:  nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"
-- One file:  … -c "lua MiniTest.run_file('tests/test_engine.lua')"
--
-- mini.nvim is cloned into .deps/ on first run (ignored by git) and kept at the
-- tag below, so every machine and every CI run tests against the same harness.
-- Because the runner uses --noplugin, plugin/bang.lua is NOT sourced
-- automatically: a child Neovim started with this file must
-- `vim.cmd("runtime plugin/bang.lua")` itself when it needs the command and the
-- default keymaps.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local mini_path = root .. "/.deps/mini.nvim"
-- renovate: datasource=github-tags depName=nvim-mini/mini.nvim
local mini_rev = "v0.18.0"

local function git(args)
  local out = vim.fn.system(vim.list_extend({ "git" }, args))
  if vim.v.shell_error ~= 0 then
    error(("git %s failed:\n%s"):format(table.concat(args, " "), out))
  end
  return vim.trim(out)
end

if not vim.uv.fs_stat(mini_path) then
  git({ "clone", "--filter=blob:none", "https://github.com/nvim-mini/mini.nvim", mini_path })
end

local ok, at = pcall(git, { "-C", mini_path, "describe", "--tags", "--exact-match" })
if not ok or at ~= mini_rev then
  git({ "-C", mini_path, "fetch", "--tags", "--quiet" })
  git({ "-C", mini_path, "checkout", "--quiet", mini_rev })
end

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(mini_path)

require("mini.test").setup()
