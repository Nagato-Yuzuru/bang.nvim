-- Neovim init for every demo tape: the plugin from this checkout, the display
-- options the GIFs are framed for, and screenkey.nvim showing the keys.
-- `mise run demo` clones screenkey.nvim into .deps/ at the pinned commit.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local screenkey = root .. "/.deps/screenkey.nvim"
if not vim.uv.fs_stat(screenkey) then
  error("demo: " .. screenkey .. " is missing; `mise run demo` clones it")
end
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(screenkey)

vim.o.laststatus = 0
vim.o.number = false
vim.o.swapfile = false
vim.o.cmdheight = 2

-- The float is placed from 'columns', which is only final once the UI is up.
vim.api.nvim_create_autocmd("UIEnter", {
  once = true,
  callback = function()
    require("screenkey").setup({
      win_opts = {
        row = 0,
        col = vim.o.columns - 1,
        anchor = "NE",
        width = 24,
        height = 1,
        border = "single",
        title = "",
      },
      -- g! is one key to the viewer, not g then !.
      group_mappings = true,
      -- Longer than any scene, so the keys stay up through the final hold.
      clear_after = 10,
      -- The command line already shows what is typed at the ! prompt.
      disable = { modes = { "c" } },
      keys = { ["<CR>"] = "⏎", ["<SPACE>"] = "␣" },
    })
    require("screenkey").toggle()
  end,
})
