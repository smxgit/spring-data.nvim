-- Spring Data JPA derived query method completion.
local M = {}

local defaults = {
  -- Return type of deleteBy / removeBy methods: "void" or "long".
  delete_return_type = "void",
}

M.opts = defaults

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", defaults, opts or {})
  require("spring-data.entity").setup_autocmds()
  require("spring-data.blink").setup()
  return M.opts
end

return M
