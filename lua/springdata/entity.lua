-- Résolution de l'entité d'un repository Spring Data et extraction de ses
-- champs. Seul module à dépendre à la fois de treesitter et de jdtls.
local M = {}

--- Requête treesitter isolant le premier argument générique d'une interface
--- qui étend un type dont le nom se termine par « Repository ».
---
--- Le parser java expose `extends_interfaces` sur les versions récentes et
--- `super_interfaces` sur les plus anciennes ; la requête tolère les deux en
--- ne contraignant pas le nœud intermédiaire.
local QUERY = [[
(interface_declaration
  (_
    (type_list
      (generic_type
        (type_identifier) @repo_name
        (type_arguments
          (_) @entity_name)))))
]]

local function iter_matches(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "java")
  if not ok or not parser then
    return nil
  end

  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local query_ok, query = pcall(vim.treesitter.query.parse, "java", QUERY)
  if not query_ok then
    return nil
  end

  return query, tree:root()
end

--- Nom de l'entité d'un repository, ou nil si le buffer n'en est pas un.
function M.resolve_entity_name(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local query, root = iter_matches(bufnr)
  if not query then
    return nil
  end

  for _, match in query:iter_matches(root, bufnr, 0, -1) do
    local repo_name, entity_name
    for id, nodes in pairs(match) do
      local node = type(nodes) == "table" and nodes[1] or nodes
      local capture = query.captures[id]
      local text = vim.treesitter.get_node_text(node, bufnr)
      if capture == "repo_name" then
        repo_name = text
      elseif capture == "entity_name" and not entity_name then
        entity_name = text
      end
    end

    if repo_name and repo_name:match("Repository$") and entity_name then
      return entity_name
    end
  end

  return nil
end

--- Vrai si le buffer contient une interface étendant un *Repository.
function M.is_repository(bufnr)
  return M.resolve_entity_name(bufnr) ~= nil
end

return M
