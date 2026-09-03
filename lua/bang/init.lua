-- bang.nvim -- pipe a selection, motion or text object through a shell command.
--
-- `run()` is the whole engine: it resolves the region, feeds the command, and
-- writes the output back. Every entry point (`g!`, `g!!`, `:Bang`) is a thin
-- adapter over it; see `lua/bang/adapters.lua`.

local api = vim.api

local config = require("bang.config")
local exec = require("bang.exec")
local notify = require("bang.notify")
local regions = require("bang.region")

local M = {}

---The last command that ran, for the `!` substitution of `expand_bang` (D8.2).
---Vim's own "previous external command" is not readable from Lua, so the
---plugin keeps its own. Separate from the operator's repeat state.
local prev_cmd = nil

---@param msg string
---@param expanded string|nil The command as the shell received it, when it got that far.
---@return false, string, string|nil
local function fail(msg, expanded)
  notify(msg)
  return false, msg, expanded
end

---Replace every unescaped `!` with the previous command, `\!` with a literal
---one. Textual and quote-blind, exactly like the built-in filter (DEV-1).
---@param cmd string
---@return string|nil expanded, string|nil error
local function substitute_bang(cmd)
  local out, i = {}, 1
  while i <= #cmd do
    local char = cmd:sub(i, i)
    if char == "\\" and cmd:sub(i + 1, i + 1) == "!" then
      out[#out + 1] = "!"
      i = i + 2
    elseif char == "!" then
      if not prev_cmd then
        return nil, "bang: no previous command to substitute for `!`"
      end
      out[#out + 1] = prev_cmd
      i = i + 1
    else
      out[#out + 1] = char
      i = i + 1
    end
  end
  return table.concat(out)
end

---@param result bang.ExecResult
---@return string
local function failure_message(result)
  local msg = ("bang: command exited with %d, the buffer was left unchanged"):format(result.code)
  if result.stderr ~= "" then
    msg = msg .. "\n" .. vim.trim(result.stderr)
  end
  return msg
end

---@class bang.RunOpts
---@field bang boolean|nil Write the output even when the command fails, like `:Bang!`.
---@field buf integer|nil Buffer to act on. 0 or nil means the current buffer.
---@field expanded boolean|nil Internal: `cmd` has already been through `cmdline-special`
---expansion, so this run must not expand it again (F5). Set by the repeat path.

---@class bang.Region
---@field type "v"|"V"|"\22" Charwise, linewise or blockwise.
---@field start { lnum: integer, col: integer } 1-based line and byte column.
---@field finish { lnum: integer, col: integer } Inclusive end; `col = vim.v.maxcol` means end of line.
---@field block bang.BlockHint|nil Internal: how a blockwise adapter names the block's columns (D-2).

---Filter `region` through `cmd` and replace it with the output.
---
---Runs the whole pipeline, notifications included, and leaves the buffer
---byte-identical whenever anything goes wrong.
---@param cmd string Shell command line, run through 'shell'.
---@param region bang.Region
---@param opts bang.RunOpts|nil
---@return boolean ok, string|nil message, string|nil expanded Message is set when
---`ok` is false; `expanded` is the command as the shell received it, which is what
---a repeat must re-run (R17, F5).
function M.run(cmd, region, opts)
  opts = opts or {}
  local cfg, config_err = config.get()
  if not cfg then
    return fail(config_err --[[@as string]])
  end

  local buf = opts.buf or 0
  if buf == 0 then
    buf = api.nvim_get_current_buf()
  end
  if not api.nvim_buf_is_valid(buf) then
    return fail(("bang: buffer %s is not valid"):format(vim.inspect(opts.buf)))
  end
  if not vim.bo[buf].modifiable then
    return fail("bang: buffer is not modifiable, nothing was replaced")
  end
  if type(cmd) ~= "string" or vim.trim(cmd) == "" then
    return fail("bang: no command given")
  end

  -- Expansion happens exactly once, here, on the command as typed. A repeat
  -- arrives already expanded and must not go through it again, or `\%` would
  -- turn into the buffer's name on the second run (F5).
  if not opts.expanded then
    -- Vim expands `%` and friends first, then substitutes `!`, so the
    -- remembered previous command is the one the shell actually saw.
    cmd = exec.expand(cmd)
    if cfg.expand_bang then
      local substituted, subst_err = substitute_bang(cmd)
      if not substituted then
        return fail(subst_err --[[@as string]])
      end
      cmd = substituted
    end
  end

  local normalized, norm_err = regions.normalize(region)
  if not normalized then
    return fail(norm_err --[[@as string]], cmd)
  end
  local resolved, resolve_err = regions.resolve(buf, normalized)
  if not resolved then
    return fail(resolve_err --[[@as string]], cmd)
  end

  local input = regions.stdin(resolved, regions.text(buf, resolved))
  local result, exec_err = exec.run(cmd, input, cfg.timeout)
  if not result then
    return fail(exec_err --[[@as string]], cmd)
  end

  -- Failure handling (D6.3, D6.4). `keep` reports and writes nothing;
  -- `replace` and `:Bang!` restore the built-in's parity, stderr appended.
  local body
  if opts.bang == true or cfg.on_error == "replace" then
    body = result.stdout .. result.stderr
  elseif result.code ~= 0 then
    return fail(failure_message(result), cmd)
  else
    body = result.stdout
    if result.stderr ~= "" then
      notify("bang: " .. vim.trim(result.stderr), vim.log.levels.WARN)
    end
  end

  -- A charwise region that ends on an empty line hands the command a stdin that
  -- already ends in a newline; stripping the output's would eat that line (F3).
  local kept_newline = resolved.kind == "char" and input:sub(-1) == "\n"
  local write_err = regions.write(buf, resolved, regions.output_lines(body, kept_newline))
  if write_err then
    return fail(write_err, cmd)
  end
  prev_cmd = cmd
  return true, nil, cmd
end

---Every command run through `:Bang`, newest first, without duplicates.
---@return string[]
function M.history()
  return require("bang.history").list()
end

---Merge `opts` into `vim.g.bang`. Optional: the plugin works zero-config.
---@param opts table|nil
function M.setup(opts)
  local cfg = config.setup(opts)
  require("bang.adapters").default_keymaps(cfg.keymaps)
end

return M
