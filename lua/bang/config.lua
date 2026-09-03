-- Configuration: defaults, validation, and the `vim.g.bang` merge.
--
-- Options are read at call time, so changing `vim.g.bang` takes effect for the
-- next run. `keymaps` is the exception: it is read once, when the plugin loads.

local M = {}

---@class bang.Config
---@field on_error "keep"|"replace" Whether a failing command may overwrite the region.
---@field timeout integer How long to wait for the command, in milliseconds.
---@field keymaps boolean Create the default `g!` / `g!!` keymaps.
---@field expand_bang boolean Replace every unescaped `!` with the previous command.

---Built-in defaults. Treat as read-only.
---@type bang.Config
M.defaults = {
  on_error = "keep",
  timeout = 30000,
  keymaps = true,
  expand_bang = false,
}

---The reason `opts` cannot be used, or nil when it can.
---@param opts table A full or partial configuration.
---@param source string Where the table came from, for the message.
---@return string|nil
local function invalid(opts, source)
  if type(opts) ~= "table" then
    return ("bang: %s must be a table, got %s"):format(source, type(opts))
  end
  for key in pairs(opts) do
    if M.defaults[key] == nil then
      return ("bang: %s has no option %s"):format(source, vim.inspect(key))
    end
  end
  local on_error = opts.on_error
  if on_error ~= nil and on_error ~= "keep" and on_error ~= "replace" then
    return ('bang: %s.on_error must be "keep" or "replace", got %s'):format(
      source,
      vim.inspect(on_error)
    )
  end
  local timeout = opts.timeout
  if timeout ~= nil and (type(timeout) ~= "number" or timeout <= 0) then
    return ("bang: %s.timeout must be a positive number of milliseconds, got %s"):format(
      source,
      vim.inspect(timeout)
    )
  end
  for _, name in ipairs({ "keymaps", "expand_bang" }) do
    local value = opts[name]
    if value ~= nil and type(value) ~= "boolean" then
      return ("bang: %s.%s must be a boolean, got %s"):format(source, name, vim.inspect(value))
    end
  end
end

---The effective configuration: defaults overridden by `vim.g.bang`.
---Reports rather than raises, so that `run()` has one error channel (R8).
---@return bang.Config|nil config, string|nil error
function M.get()
  local user = vim.g.bang
  if user == nil then
    return vim.deepcopy(M.defaults)
  end
  local err = invalid(user, "vim.g.bang")
  if err then
    return nil, err
  end
  return vim.tbl_deep_extend("force", M.defaults, user)
end

---Merge `opts` into `vim.g.bang` and return the result (D8.1). Raises on a bad
---value: `setup()` is the one place a configuration mistake is a programming
---error rather than a runtime condition.
---@param opts table|nil
---@return bang.Config
function M.setup(opts)
  opts = opts or {}
  local err = invalid(opts, "setup()")
  if err then
    error(err, 0)
  end
  local merged = vim.tbl_deep_extend("force", M.defaults, vim.g.bang or {}, opts)
  vim.g.bang = merged
  return merged
end

return M
