-- Complétion des derived query methods Spring Data JPA.
local M = {}

local defaults = {
  -- Type de retour des méthodes deleteBy / removeBy : "void" ou "long".
  delete_return_type = "void",
}

M.opts = defaults

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", defaults, opts or {})
  require("spring-data.entity").setup_autocmds()
  return M.opts
end

return M
