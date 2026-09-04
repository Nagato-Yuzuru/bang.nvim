-- Running the command: the shell half of the pipeline.

local M = {}

---@class bang.ExecResult
---@field code integer Exit code.
---@field stdout string
---@field stderr string

-- `:` modifiers that may follow a special item, as in `%:p:h`.
local MODIFIER = "[phtre8~.S]"

-- `<…>` items worth expanding in a filter command. The rest -- `<afile>`,
-- `<abuf>`, `<sfile>`, `<slnum>`, `<script>`, `<stack>`, `<SID>`, `<amatch>` --
-- only mean something inside an autocommand or a sourced script, so they reach
-- the shell as typed (R12).
local EXPANDABLE = { cword = true, cWORD = true, cfile = true, cexpr = true }

---The special item starting at `index`, without its `:` modifiers.
---@param cmd string
---@param index integer
---@return string|nil
local function item_at(cmd, index)
  local token = cmd:match("^%%<?", index)
    or cmd:match("^##", index)
    or cmd:match("^#<?%d+", index)
    or cmd:match("^#<", index)
    or cmd:match("^#", index)
  if token then
    return token
  end
  local name = cmd:match("^<(%a+)>", index)
  return name and EXPANDABLE[name] and ("<" .. name .. ">") or nil
end

---Expand the items the built-in filter expands -- `%`, `#`, `<cword>` and
---friends, with their `:` modifiers -- and leave every other byte alone.
---
---`expandcmd()`, which |:edit| uses, does more than `!` does: it expands `$VAR`
---and `~`, and it halves every backslash. Measured against `:%!`, that turns
---`sed 's/,/\n/g'` into `sed 's/,/n/g'` and `printf '$HOME'` into the value of
---$HOME, neither of which the built-in filter does (D6.1, D2.1).
---@param cmd string
---@return string
function M.expand(cmd)
  local out, i = {}, 1
  while i <= #cmd do
    local char = cmd:sub(i, i)
    if char == "\\" then
      -- In front of an item it could expand, Vim drops exactly one backslash
      -- and leaves the item alone: `\%` reaches the shell as `%`, `\\%` as
      -- `\%` (measured against `:!`, R12).
      local run = cmd:match("^\\+", i)
      local after = cmd:sub(i + #run, i + #run)
      if after:match("[%%#<]") then
        out[#out + 1] = run:sub(2) .. after
        i = i + #run + 1
      else
        out[#out + 1] = run
        i = i + #run
      end
    else
      local item = item_at(cmd, i)
      if not item then
        out[#out + 1] = char
        i = i + 1
      else
        local stop = i + #item
        while cmd:sub(stop, stop) == ":" and cmd:sub(stop + 1, stop + 1):match(MODIFIER) do
          stop = stop + 2
        end
        item = cmd:sub(i, stop - 1)
        -- An item that expands to nothing -- `%` in an unnamed buffer -- is
        -- left as typed, which is what expandcmd() does with it too.
        local ok, value = pcall(vim.fn.expand, item)
        out[#out + 1] = (ok and value ~= "") and value or item
        i = stop
      end
    end
  end
  return table.concat(out)
end

---Split an option that holds a command into words, the way Neovim splits
---'shell' before spawning: on whitespace, honouring double quotes, with a
---backslash escaping a space (`option-backslash`) or a character inside quotes.
---A backslash anywhere else is kept, so that a Windows path or a UNC share
---survives the split (R6, F11).
---@param value string
---@return string[]
local function words(value)
  local out, current, quoted = {}, {}, false
  local i = 1
  local function flush()
    if #current > 0 or quoted then
      out[#out + 1] = table.concat(current)
      current = {}
    end
  end
  while i <= #value do
    local char = value:sub(i, i)
    local next_char = value:sub(i + 1, i + 1)
    if char == '"' then
      quoted = not quoted
      i = i + 1
    elseif char == "\\" and (quoted or next_char:match("%s")) and next_char ~= "" then
      current[#current + 1] = next_char
      i = i + 2
    elseif char:match("%s") and not quoted then
      flush()
      i = i + 1
    else
      current[#current + 1] = char
      i = i + 1
    end
  end
  flush()
  return out
end

---The program 'shell' names, and the arguments it carries, split the way
---`M.argv` splits them. Exported so that `:checkhealth bang` can ask whether
---the program the plugin would spawn exists (#17).
---@return string[]
function M.shell_words()
  return words(vim.o.shell)
end

---The argv `!` would use. Both 'shell' and 'shellcmdflag' may carry arguments
---(`csh -f`, and pwsh sets three flags), so both are split (D6.1, R6).
---@param cmd string
---@return string[]
function M.argv(cmd)
  local argv = M.shell_words()
  vim.list_extend(argv, words(vim.o.shellcmdflag))
  argv[#argv + 1] = cmd
  return argv
end

---Run `cmd` with `stdin` on its standard input and wait for it.
---A timeout and a Ctrl-C both end as SIGKILL with exit code 124 (D6.2); the
---elapsed time is what tells them apart.
---
---The command gets its own process group (`detach`) so that a timeout can kill
---the whole pipeline. `wait()` kills only the shell; a child the shell forked --
---every pipeline, and on dash even a lone command -- would keep stdout open and
---hold the result back, so `wait()` returned nil (CI-1).
---@param cmd string
---@param stdin string
---@param timeout integer Milliseconds.
---@return bang.ExecResult|nil result, string|nil error
function M.run(cmd, stdin, timeout)
  local started = vim.uv.hrtime()
  local ok, proc = pcall(vim.system, M.argv(cmd), {
    stdin = stdin,
    text = true,
    cwd = vim.fn.getcwd(),
    detach = true,
  })
  if not ok then
    return nil, ("bang: could not run %s: %s"):format(vim.o.shell, proc)
  end

  local result = proc:wait(timeout)
  if result == nil then
    -- The shell is dead, but a child of it still holds the pipes.
    pcall(vim.uv.kill, -proc.pid, "sigkill")
    result = proc:wait(timeout)
  end
  local elapsed = (vim.uv.hrtime() - started) / 1e6

  if result == nil or (result.code == 124 and result.signal == 9) then
    if elapsed >= timeout * 0.9 then
      return nil, ("bang: command timed out after %d ms, nothing was replaced"):format(timeout)
    end
    return nil,
      ("bang: command interrupted after %d ms, nothing was replaced"):format(math.floor(elapsed))
  end
  -- A child killed by a signal reports code 0, so its empty output would
  -- otherwise look like a successful run that deletes the region (R4).
  if result.signal ~= 0 then
    return nil,
      ("bang: command was killed by signal %d, nothing was replaced"):format(result.signal)
  end
  return { code = result.code, stdout = result.stdout or "", stderr = result.stderr or "" }
end

return M
