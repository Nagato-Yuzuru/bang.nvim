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

---Whether everything before the command name could be a range and modifiers.
---The only letters a range holds are mark names, right after a quote.
---@param prefix string
---@return boolean
local function only_range_before(prefix)
  local rest = M.range_text(prefix):gsub("'.", "")
  -- Line numbers, offsets and separators, or a complete search range.
  return rest:match("^[%s%d%.%$%%,;%+%-<>]*$") ~= nil
    or rest:match("^[/?][^/?]*[/?][%s%d%.%$%%,;%+%-<>]*$") ~= nil
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
  local name = entry:find("Bang", 1, true)
  if not name then
    return nil
  end
  local ok, parsed = pcall(vim.api.nvim_parse_cmd, entry, {})
  if not ok then
    -- An unresolvable range -- an unset mark, a pattern matching nothing --
    -- says nothing about the command name, so try again without it. Only then:
    -- re-parsing anything else would let a `:substitute` whose pattern contains
    -- "Bang" surface its fragments in the picker (F10).
    local message = tostring(parsed)
    if message:find(NAME_ERROR, 1, true) or not only_range_before(entry:sub(1, name - 1)) then
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
