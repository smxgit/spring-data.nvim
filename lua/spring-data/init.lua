-- Spring Data JPA derived query method completion.
local M = {}

local defaults = {
  -- Return type of deleteBy / removeBy methods: "void" or "long".
  delete_return_type = "void",

  -- Return type of streamBy methods: "List" or "Stream".
  --
  -- Off by default because Spring does not tie the two: `stream` is one
  -- of the six interchangeable general query keywords, and Stream<T> is
  -- a return type the developer opts into. It also comes with
  -- obligations — a surrounding transaction and a try-with-resources —
  -- that the plugin can't write for you.
  stream_return_type = "List",
}

M.opts = defaults

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", defaults, opts or {})
  require("spring-data.entity").setup_autocmds()
  require("spring-data.blink").setup()
  return M.opts
end

return M
