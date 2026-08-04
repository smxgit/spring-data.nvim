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

-- Cache des champs, indexé par nom d'entité. Invalidé sur BufWritePost du
-- fichier de l'entité, via setup_autocmds.
local cache = {}
local uri_index = {}

-- Requêtes `M.fields` en cours par nom d'entité : deux demandes concurrentes
-- pour la même entité partagent une seule requête workspace/symbol au lieu
-- d'en déclencher deux, et sont toutes deux résolues à la réponse unique.
local pending = {}

--- Requête treesitter isolant chaque déclaration de champ.
local FIELDS_QUERY = [[
(field_declaration) @field
]]

--- Nom simple d'une annotation, avec ses arguments éventuels, sans
--- qualification de paquetage : « @jakarta.persistence.Id » devient « Id »,
--- « @Column(unique = true) » reste « Column(unique = true) ».
---
--- parser.is_unique_field (Task 9) compare par égalité stricte au nom
--- simple (`annotation == "Id"`) et cherche les sous-chaînes « Column » /
--- « unique » pour le second cas : une annotation totalement qualifiée
--- (légale en Java, `@jakarta.persistence.Id`) casserait ces deux
--- vérifications si elle n'était pas normalisée ici.
local function annotation_text(node, bufnr)
  local name_node = node:field("name")[1]
  if not name_node then
    return nil
  end

  local qualified = vim.treesitter.get_node_text(name_node, bufnr)
  local simple = qualified:match("([%w_]+)$") or qualified

  local args_node = node:field("arguments")[1]
  if args_node then
    simple = simple .. vim.treesitter.get_node_text(args_node, bufnr)
  end

  return simple
end

--- Extrait les champs d'un buffer Java : nom, type et annotations.
--- Les annotations et modificateurs (static, transient) vivent dans le
--- nœud `modifiers` du `field_declaration` — documentSymbol ne les
--- remonterait pas, d'où le passage par treesitter sur le buffer réel.
local function extract_fields(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "java")
  if not ok or not parser then
    return {}
  end

  local tree = parser:parse()[1]
  if not tree then
    return {}
  end

  local query_ok, query = pcall(vim.treesitter.query.parse, "java", FIELDS_QUERY)
  if not query_ok then
    return {}
  end

  local fields = {}

  for _, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
    local java_type
    local annotations = {}
    local names = {}
    local skip = false

    for child in node:iter_children() do
      local kind = child:type()
      if kind == "modifiers" then
        for modifier in child:iter_children() do
          local mtype = modifier:type()
          if mtype == "annotation" or mtype == "marker_annotation" then
            local text = annotation_text(modifier, bufnr)
            if text then
              annotations[#annotations + 1] = text
            end
          elseif mtype == "static" or mtype == "transient" then
            -- Un champ statique ou transient n'est pas persisté : il ne
            -- doit pas être proposé.
            skip = true
          end
        end
      elseif kind == "variable_declarator" then
        local name_node = child:field("name")[1]
        if name_node then
          names[#names + 1] = vim.treesitter.get_node_text(name_node, bufnr)
        end
      elseif java_type == nil then
        -- Premier enfant qui n'est ni les modificateurs ni un déclarateur :
        -- c'est le nœud de type (type_identifier, generic_type, etc.).
        java_type = vim.treesitter.get_node_text(child, bufnr)
      end
    end

    if not skip and java_type then
      -- `private String a, b;` déclare plusieurs champs dans un seul
      -- field_declaration : un par déclarateur, type et annotations
      -- partagés.
      for _, name in ipairs(names) do
        fields[#fields + 1] = {
          name = name,
          java_type = java_type,
          annotations = annotations,
        }
      end
    end
  end

  return fields
end

--- Charge le fichier d'une URI dans un buffer et en extrait les champs.
local function fields_from_uri(uri)
  local bufnr = vim.uri_to_bufnr(uri)
  vim.fn.bufload(bufnr)
  return extract_fields(bufnr)
end

--- Récupère les champs d'une entité, en passant par le cache.
--- jdtls localise le fichier via workspace/symbol, treesitter en extrait le
--- contenu — documentSymbol ne remonterait pas les annotations.
function M.fields(entity_name, callback)
  if cache[entity_name] then
    callback(cache[entity_name])
    return
  end

  if pending[entity_name] then
    -- Une requête est déjà en vol pour cette entité : on s'accroche à sa
    -- réponse plutôt que d'en émettre une seconde.
    table.insert(pending[entity_name], callback)
    return
  end

  local clients = vim.lsp.get_clients({ name = "jdtls" })
  if #clients == 0 then
    callback({})
    return
  end

  pending[entity_name] = { callback }

  local function resolve(fields)
    local waiters = pending[entity_name]
    pending[entity_name] = nil
    for _, cb in ipairs(waiters or {}) do
      cb(fields)
    end
  end

  clients[1]:request("workspace/symbol", { query = entity_name }, function(err, results)
    if err or not results or #results == 0 then
      resolve({})
      return
    end

    local uri
    for _, symbol in ipairs(results) do
      if symbol.name == entity_name then
        uri = symbol.location and symbol.location.uri
        break
      end
    end

    if not uri then
      resolve({})
      return
    end

    local fields = fields_from_uri(uri)
    cache[entity_name] = fields
    uri_index[vim.uri_to_fname(uri)] = entity_name
    resolve(fields)
  end)
end

--- Vide l'entrée de cache d'une entité, ou tout le cache si aucun nom donné.
function M.invalidate(entity_name)
  if entity_name then
    cache[entity_name] = nil
  else
    cache = {}
    uri_index = {}
  end
end

--- Invalide le cache d'une entité dès que son fichier est sauvegardé.
function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("SpringDataEntityCache", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.java",
    callback = function(args)
      local entity_name = uri_index[args.file]
      if entity_name then
        M.invalidate(entity_name)
      end
    end,
  })
end

return M
