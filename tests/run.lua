-- Suite entry point: `luajit tests/run.lua` from the repo root.
local root = (arg and arg[0] or ""):match("^(.*)/tests/run%.lua$") or "."

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local harness = require("harness")

local specs = {
  "grammar_spec",
  "parser_spec",
  "source_spec",
}

for _, spec in ipairs(specs) do
  require(spec)
end

os.exit(harness.report() and 0 or 1)
