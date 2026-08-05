-- Minimal test framework. No dependencies: must run under bare `luajit`.
local M = {}

local current_suite = nil
local stats = { passed = 0, failed = 0 }
local failures = {}

local function deep_equal(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

-- Renders a value legibly in a failure message, keys sorted for
-- deterministic output.
local function render(value, indent)
  indent = indent or ""
  if type(value) == "string" then
    return string.format("%q", value)
  end
  if type(value) ~= "table" then
    return tostring(value)
  end
  local keys = {}
  for k in pairs(value) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(x, y)
    return tostring(x) < tostring(y)
  end)
  if #keys == 0 then
    return "{}"
  end
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = indent .. "  " .. tostring(k) .. " = " .. render(value[k], indent .. "  ")
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

function M.describe(name, fn)
  current_suite = name
  fn()
  current_suite = nil
end

function M.it(name, fn)
  local label = (current_suite and (current_suite .. " › ") or "") .. name
  local ok, err = pcall(fn)
  if ok then
    stats.passed = stats.passed + 1
  else
    stats.failed = stats.failed + 1
    failures[#failures + 1] = { label = label, err = tostring(err) }
  end
end

function M.eq(actual, expected)
  if not deep_equal(actual, expected) then
    error("expected:\n" .. render(expected) .. "\n\ngot:\n" .. render(actual), 2)
  end
end

function M.truthy(value, message)
  if not value then
    error(message or "false or nil value", 2)
  end
end

function M.report()
  for _, f in ipairs(failures) do
    io.write("FAIL  ", f.label, "\n", f.err, "\n\n")
  end
  io.write(string.format("%d passed, %d failed\n", stats.passed, stats.failed))
  return stats.failed == 0
end

return M
