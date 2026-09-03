-- Identity fuzz: random buffers, random regions, `cat` and `sort`.
--
-- `cat` is an identity on every region kind, and that is the property the
-- example tests could not state: a charwise region ending on an empty line
-- (whose stdin already ends in a newline) and a block over lines with their own
-- trailing spaces both come back byte-identical or not at all. `sort` on a
-- linewise region is a permutation of the region's lines and touches nothing
-- outside it.
--
-- A refusal also satisfies the identity (D7.6 leaves the buffer byte-identical),
-- so the run is only meaningful if most cases actually go through; the success
-- rate is asserted to keep a suite that refuses everything from passing.
--
-- Deterministic: `BANG_FUZZ_SEED` overrides the seed, `BANG_FUZZ_CASES` the
-- count, `BANG_SKIP_FUZZ=1` skips the file. The seed is printed on every run.

local H = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local SEED = tonumber(vim.env.BANG_FUZZ_SEED or "") or 20260902
local N_IDENTITY = tonumber(vim.env.BANG_FUZZ_CASES or "") or 200
local N_SORT = math.max(1, math.floor(N_IDENTITY / 2))

-- Deliberately includes what the point tests kept out of reach: empty lines,
-- lines that are only spaces, trailing spaces, tabs and a multibyte character.
local ALPHABET = { "a", "b", "z", "A", "Q", "1", "-", " ", " ", " ", "\t", "中" }

local function random_line()
  local chars = {}
  for i = 1, math.random(0, 8) do
    chars[i] = ALPHABET[math.random(#ALPHABET)]
  end
  return chars
end

--- Byte column of the first and last byte of every character on a line.
---
--- Regions are built from these so that a column never lands inside a multibyte
--- character, which is not a case the public contract defines.
local function columns(chars)
  local starts, ends, at = {}, {}, 1
  for i, ch in ipairs(chars) do
    starts[i], ends[i] = at, at + #ch - 1
    at = at + #ch
  end
  return starts, ends
end

local function random_buffer()
  local lines, cols = {}, {}
  for i = 1, math.random(1, 5) do
    local chars = random_line()
    lines[i] = table.concat(chars)
    local starts, ends = columns(chars)
    cols[i] = { n = #chars, starts = starts, ends = ends }
  end
  return lines, cols
end

local function random_region(lines, cols, kind)
  local l1 = math.random(#lines)
  local l2 = math.random(l1, #lines)

  if kind == "V" then
    return { type = "V", start = { lnum = l1, col = 1 }, finish = { lnum = l2, col = H.MAXCOL } }
  end

  if kind == "\22" then
    local widest = 0
    for _, line in ipairs(lines) do
      widest = math.max(widest, #line)
    end
    -- Reach past the end of every line often enough to exercise the padding.
    local c1 = math.random(1, widest + 1)
    local c2 = math.random(c1, widest + 3)
    return { type = "\22", start = { lnum = l1, col = c1 }, finish = { lnum = l2, col = c2 } }
  end

  local first, last = cols[l1], cols[l2]
  if first.n == 0 and last.n == 0 then
    return { type = "v", start = { lnum = l1, col = 0 }, finish = { lnum = l2, col = 0 } }
  end
  local i = first.n == 0 and 0 or math.random(first.n)
  local j = last.n == 0 and 0 or math.random(last.n)
  if l1 == l2 and i ~= 0 and j ~= 0 and j < i then
    i, j = j, i
  end
  return {
    type = "v",
    start = { lnum = l1, col = i == 0 and 0 or first.starts[i] },
    finish = { lnum = l2, col = j == 0 and 0 or last.ends[j] },
  }
end

local KINDS = { "v", "V", "\22" }

local function generate(n, kinds)
  math.randomseed(SEED)
  local cases = {}
  for i = 1, n do
    local lines, cols = random_buffer()
    cases[i] = {
      i = i,
      lines = lines,
      region = random_region(lines, cols, kinds[math.random(#kinds)]),
    }
  end
  return cases
end

--- Run every case in one round trip and bring back only what failed.
local function drive(cases, cmd)
  return child.lua(
    [[
      local cases, cmd, maxcol = ...
      local bang = require("bang")
      local report = { n_ok = 0, fails = {} }
      for _, case in ipairs(cases) do
        vim.api.nvim_buf_set_lines(0, 0, -1, true, case.lines)
        local before = vim.api.nvim_buf_get_lines(0, 0, -1, true)
        local region = vim.deepcopy(case.region)
        if region.finish.col == maxcol then
          region.finish.col = vim.v.maxcol
        end
        local called, ok, msg = pcall(bang.run, cmd, region, {})
        local after = vim.api.nvim_buf_get_lines(0, 0, -1, true)
        if called and ok == true then
          report.n_ok = report.n_ok + 1
        end
        if not called and #report.fails < 5 then
          table.insert(report.fails, {
            i = case.i, why = "run() raised", detail = tostring(ok),
            region = case.region, before = before, after = after,
          })
        end
        case.before, case.after, case.ok, case.msg = before, after, called and ok or nil, msg
      end
      return { n_ok = report.n_ok, fails = report.fails, cases = cases }
    ]],
    { cases, cmd, H.MAXCOL }
  )
end

local function describe(case)
  return string.format(
    "case %d  region=%s\n  before=%s\n  after =%s\n  ok=%s msg=%s",
    case.i,
    vim.inspect(case.region, { newline = " ", indent = "" }),
    vim.inspect(case.before, { newline = " ", indent = "" }),
    vim.inspect(case.after, { newline = " ", indent = "" }),
    tostring(case.ok),
    tostring(case.msg)
  )
end

local function sorted_copy(list)
  local copy = vim.deepcopy(list)
  table.sort(copy)
  return copy
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if vim.env.BANG_SKIP_FUZZ == "1" then
        MiniTest.skip("BANG_SKIP_FUZZ=1")
      end
      H.setup_child(child, { plugin = false })
      MiniTest.add_note(("seed %d, rerun with BANG_FUZZ_SEED=%d"):format(SEED, SEED))
    end,
    post_once = child.stop,
  },
})

T["F3/F8 cat is an identity on every region kind"] = function()
  local report = drive(generate(N_IDENTITY, KINDS), "cat")
  eq(#report.fails, 0, {
    fail_reason = ("seed %d: run() raised\n%s"):format(SEED, vim.inspect(report.fails[1])),
  })

  local broken = {}
  for _, case in ipairs(report.cases) do
    if not vim.deep_equal(case.before, case.after) and #broken < 3 then
      broken[#broken + 1] = describe(case)
    end
  end
  eq(broken, {}, {
    fail_reason = ("seed %d: `cat` was not an identity\n%s"):format(
      SEED,
      table.concat(broken, "\n")
    ),
  })

  -- A suite that refused every case would satisfy the identity vacuously.
  eq(report.n_ok > N_IDENTITY / 2, true, {
    fail_reason = ("seed %d: only %d of %d cases ran"):format(SEED, report.n_ok, N_IDENTITY),
  })
end

T["D7.2 sort permutes a linewise region and touches nothing outside it"] = function()
  local report = drive(generate(N_SORT, { "V" }), "sort")
  eq(#report.fails, 0, {
    fail_reason = ("seed %d: run() raised\n%s"):format(SEED, vim.inspect(report.fails[1])),
  })

  local broken = {}
  for _, case in ipairs(report.cases) do
    local l1, l2 = case.region.start.lnum, case.region.finish.lnum
    local outside_before, outside_after = {}, {}
    for i, line in ipairs(case.before) do
      if i < l1 or i > l2 then
        outside_before[#outside_before + 1] = line
      end
    end
    for i, line in ipairs(case.after) do
      if i < l1 or i > l2 then
        outside_after[#outside_after + 1] = line
      end
    end
    local permuted = vim.deep_equal(sorted_copy(case.before), sorted_copy(case.after))
    local kept = vim.deep_equal(outside_before, outside_after)
    if (not permuted or not kept) and #broken < 3 then
      broken[#broken + 1] = describe(case)
    end
  end
  eq(broken, {}, {
    fail_reason = ("seed %d: `sort` was not a permutation\n%s"):format(
      SEED,
      table.concat(broken, "\n")
    ),
  })

  eq(report.n_ok > N_SORT / 2, true, {
    fail_reason = ("seed %d: only %d of %d cases ran"):format(SEED, report.n_ok, N_SORT),
  })
end

return T
