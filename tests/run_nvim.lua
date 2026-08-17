-- Entry point for the specs that need a real Neovim (treesitter over Java
-- buffers): `nvim --headless -l tests/run_nvim.lua` from the repo root.
--
-- Kept separate from tests/run.lua on purpose: the pure suite must keep
-- running under bare luajit, with no Neovim anywhere near it.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local harness = require("harness")

-- Fail loudly rather than reporting phantom passes: every spec here needs
-- the java parser.
if not pcall(vim.treesitter.query.parse, "java", "(class_declaration) @c") then
  io.write("java treesitter parser missing: run :TSInstall java\n")
  os.exit(1)
end

require("entity_spec")

os.exit(harness.report() and 0 or 1)
