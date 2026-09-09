-- Command history. The `:` command-line history is the only store (D9.1):
-- `:Bang` lines typed at the command line land there by themselves, shada
-- persists them, `q:` shows them and `@:` replays them.

local M = {}

-- "Not an editor command": the one parse failure that is about the command
-- name rather than the range. Marks that are not set, patterns that match
-- nothing and bad offsets all fail on the range, and a search range that finds
-- nothing fails with no error code at all -- so this is the tell, and
-- `only_range_before` is what keeps a foreign command out of the fallback (F10).
local NAME_ERROR = "E492:"

---The range text of a command line: what is left of the command name once the
---leading colons, blanks and modifiers are gone. A range never starts with a
---letter, so a leading word can only be a modifier -- and a modifier is not a
---range (F6). The `:Bang` adapter reads its range through this as well.
---@param prefix string
---@return string
function M.range_text(prefix)
  local rest = prefix:gsub("^%s*:*%s*", "")
  while rest:match("^%a") do
    rest = rest:gsub("^%a+!?%s*:*%s*", "")
  end
  return rest
end

---`text` with every complete search pattern -- `/pat/`, `?pat?`, a backslash
---escaping the delimiter -- taken out, and every other escaped character with
---it (`\/`, `\?` and `\&` are ranges too). Nil when a pattern is left open.
---@param text string
---@return string|nil
local function without_patterns(text)
  local out, i = {}, 1
  while i <= #text do
    local char = text:sub(i, i)
    if char == "\\" then
      i = i + 2
    elseif char == "/" or char == "?" then
      local j = i + 1
      while j <= #text and text:sub(j, j) ~= char do
        j = j + (text:sub(j, j) == "\\" and 2 or 1)
      end
      if j > #text then
        return nil
      end
      i = j + 1
    else
      out[#out + 1] = char
      i = i + 1
    end
  end
  return table.concat(out)
end

---Whether everything before the command name could be a range and modifiers.
---The only letters a range holds are mark names, right after a quote, and
---whatever its search patterns contain.
---@param prefix string
---@return boolean
local function only_range_before(prefix)
  local rest = without_patterns(M.range_text(prefix))
  -- Marks, then line numbers, offsets and separators.
  return rest ~= nil and rest:gsub("'.", ""):match("^[%s%d%.%$%%,;%+%-<>]*$") ~= nil
end

---Where the command name of a `:Bang` line starts: the first "Bang" that only
---a range and modifiers precede. A pattern range may contain the word itself,
---as in `/Bang/Bang tr a-z A-Z`, and that one is part of the range (#52).
---@param entry string
---@return integer|nil
function M.command_name(entry)
  local from = 1
  while true do
    local pos = entry:find("Bang", from, true)
    if pos == nil or only_range_before(entry:sub(1, pos - 1)) then
      return pos
    end
    from = pos + 1
  end
end

---Record a command line, as if the user had typed it. A duplicate moves to the
---top of the history instead of being added twice.
---@param entry string
function M.record(entry)
  vim.fn.histadd(":", entry)
end

---The command text of a `:` history entry, or nil when it is not a `:Bang`.
---Vim itself decides what is a `:Bang`, so every range form it accepts --
---`'a,'b`, `/pat/`, `.,.+3`, `%` -- is recognised (R14).
---@param entry string
---@return string|nil
function M.parse(entry)
  local name = M.command_name(entry)
  if not name then
    return nil
  end
  local ok, parsed = pcall(vim.api.nvim_parse_cmd, entry, {})
  if not ok then
    -- An unresolvable range -- an unset mark, a pattern matching nothing --
    -- says nothing about the command name, so try again without it. Only then:
    -- `command_name` already refused to cut inside a `:substitute` whose
    -- pattern contains "Bang", so its fragments cannot surface in the picker
    -- (F10).
    local message = tostring(parsed)
    if message:find(NAME_ERROR, 1, true) then
      return nil
    end
    ok, parsed = pcall(vim.api.nvim_parse_cmd, entry:sub(name), {})
  end
  if not ok or parsed.cmd ~= "Bang" then
    return nil
  end
  -- Take the text as typed rather than `parsed.args`, whose whitespace split
  -- would not survive a round trip back to the shell.
  local rest = entry:sub(name + #"Bang")
  if rest:sub(1, 1) == "!" then
    rest = rest:sub(2)
  end
  return vim.trim(rest)
end

---Every command run through `:Bang`, newest first, without duplicates (D9.3).
---@return string[]
function M.list()
  local seen, out = {}, {}
  for i = vim.fn.histnr(":"), 1, -1 do
    local cmd = M.parse(vim.fn.histget(":", i))
    if cmd and cmd ~= "" and not seen[cmd] then
      seen[cmd] = true
      out[#out + 1] = cmd
    end
  end
  return out
end

return M
