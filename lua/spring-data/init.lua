-- Spring Data JPA derived query method completion.
local M = {}

-- No option today. Where Spring leaves the return type open — void or
-- the delete count, a collection or a Stream — every candidate is offered
-- in the completion menu instead: that decision belongs to the call site,
-- not to the project.
local defaults = {}

M.opts = defaults

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", defaults, opts or {})
  require("spring-data.entity").setup_autocmds()
  require("spring-data.blink").setup()
  return M.opts
end

return M
