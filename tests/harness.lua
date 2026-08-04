-- Mini framework de test. Aucune dépendance : doit tourner sous `luajit` nu.
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

-- Rend une valeur lisible dans un message d'échec, clés triées pour un
-- affichage déterministe.
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
    error("attendu :\n" .. render(expected) .. "\n\nobtenu :\n" .. render(actual), 2)
  end
end

function M.truthy(value, message)
  if not value then
    error(message or "valeur fausse ou nil", 2)
  end
end

function M.raises(fn, pattern)
  local ok, err = pcall(fn)
  if ok then
    error("aucune erreur levée, attendait : " .. tostring(pattern), 2)
  end
  if pattern and not tostring(err):find(pattern, 1, true) then
    error("erreur inattendue : " .. tostring(err) .. "\nattendait : " .. pattern, 2)
  end
end

function M.report()
  for _, f in ipairs(failures) do
    io.write("ÉCHEC  ", f.label, "\n", f.err, "\n\n")
  end
  io.write(string.format("%d réussis, %d échoués\n", stats.passed, stats.failed))
  return stats.failed == 0
end

return M
