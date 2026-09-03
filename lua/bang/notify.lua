-- Every message the plugin emits goes through here.
--
-- Always deferred: an ERROR-level `vim.notify` raised inside an operator
-- function or `nvim_buf_call` aborts the enclosing `normal!` (B10), which
-- would leave a half-applied region behind.

---@param msg string
---@param level integer|nil Defaults to ERROR.
return function(msg, level)
  vim.schedule(function()
    vim.notify(msg, level or vim.log.levels.ERROR)
  end)
end
