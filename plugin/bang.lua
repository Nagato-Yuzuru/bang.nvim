-- Registration: the version gate, `:Bang`, the `<Plug>` maps and the default
-- keys. Everything here is cheap; the modules load on first use.

if vim.g.loaded_bang then
  return
end
vim.g.loaded_bang = true

-- getregionpos() and -complete=shellcmdline both arrived in 0.11.
if vim.fn.has("nvim-0.11") == 0 then
  vim.notify_once("bang.nvim requires Neovim 0.11 or newer", vim.log.levels.WARN)
  return
end

vim.api.nvim_create_user_command("Bang", function(opts)
  require("bang.adapters").command(opts)
end, {
  range = true,
  nargs = "*",
  bang = true,
  complete = "shellcmdline",
  desc = "Filter a range, or the last Visual selection, through a shell command",
})

vim.keymap.set({ "n", "x" }, "<Plug>(bang-operator)", function()
  return require("bang.adapters").operator_expr()
end, { expr = true, desc = "Filter a motion or selection through a shell command" })

vim.keymap.set("n", "<Plug>(bang-line)", function()
  return require("bang.adapters").line_expr()
end, { expr = true, desc = "Filter whole lines through a shell command" })

require("bang.adapters").setup_autocmds()

-- `keymaps` is the one option read at load time rather than at call time.
local cfg, err = require("bang.config").get()
if not cfg then
  vim.notify_once(err, vim.log.levels.ERROR)
  cfg = require("bang.config").defaults
end
if cfg.keymaps then
  require("bang.adapters").default_keymaps(true)
end
