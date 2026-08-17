-- `:checkhealth spring-data`.
--
-- Completion silently degrades when the entity's field list can't be
-- established: parser.suggestions then offers neither properties nor
-- conditions, only And / Or / OrderBy. That output is indistinguishable
-- from a genuine parse, so this module walks the same path entity.fields
-- walks and reports which layer gave up.
--
-- It deliberately duplicates part of entity.lua's chain rather than
-- calling it: the point is to see INSIDE the chain, not to learn that it
-- returned nothing.
local entity = require("spring-data.entity")

local M = {}

local health = vim.health

-- jdtls answers workspace/symbol asynchronously while `:checkhealth` runs
-- synchronously. Long enough for a warm language server, short enough not
-- to look frozen.
local TIMEOUT_MS = 5000

--- Runs an asynchronous function to completion.
--- Returns `false` if the callback never fired within TIMEOUT_MS — a
--- distinct outcome from "fired with an empty result", which is what makes
--- a slow language server reportable as a timeout instead of as zero
--- fields.
local function await(fn)
  local done = false
  local captured
  fn(function(...)
    captured = { ... }
    done = true
  end)
  vim.wait(TIMEOUT_MS, function()
    return done
  end, 50)
  return done, captured or {}
end

--- Loaded Java buffers, whatever their window state. `:checkhealth` opens
--- its own buffer, so the repository the user is editing is never the
--- current one by the time this runs: scanning every buffer is what makes
--- the check usable at all.
local function java_buffers()
  local out = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "java" then
      out[#out + 1] = bufnr
    end
  end
  return out
end

--- Superclass named in `extends`, or nil. Reported because a
--- @MappedSuperclass parent holds fields extract_fields never walks up to.
---
--- The `superclass` node is matched without naming its field, the way
--- resolve_entity_name already tolerates extends_interfaces /
--- super_interfaces: field names have moved across java parser versions,
--- and an unknown field name makes query.parse raise rather than simply
--- not match.
local SUPERCLASS_QUERY = [[
(class_declaration
  name: (identifier) @name
  (superclass (type_identifier) @super))
]]

local function superclass_of(bufnr, class_name)
  local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, "java")
  if not parser_ok or not parser then
    return nil
  end

  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local query_ok, query = pcall(vim.treesitter.query.parse, "java", SUPERCLASS_QUERY)
  if not query_ok then
    return nil
  end

  for _, match in query:iter_matches(tree:root(), bufnr, 0, -1) do
    local name, super
    for id, nodes in pairs(match) do
      local node = type(nodes) == "table" and nodes[1] or nodes
      local capture = query.captures[id]
      if capture == "name" then
        name = vim.treesitter.get_node_text(node, bufnr)
      elseif capture == "super" then
        super = vim.treesitter.get_node_text(node, bufnr)
      end
    end
    if name == class_name and super then
      return super
    end
  end

  return nil
end

--- Type declarations found in a buffer, by kind. Used to tell "the class
--- isn't there" apart from "it's there but declared as something
--- entity.lua's CLASS_QUERY doesn't match", which is what a `record`
--- entity looks like from the outside.
local DECLARATION_QUERY = [[
(class_declaration name: (identifier) @class)
(record_declaration name: (identifier) @record)
(enum_declaration name: (identifier) @enum)
(interface_declaration name: (identifier) @interface)
]]

local function declarations(bufnr)
  local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, "java")
  if not parser_ok or not parser then
    return {}
  end

  local tree = parser:parse()[1]
  if not tree then
    return {}
  end

  local query_ok, query = pcall(vim.treesitter.query.parse, "java", DECLARATION_QUERY)
  if not query_ok then
    return {}
  end

  local out = {}
  for _, match in query:iter_matches(tree:root(), bufnr, 0, -1) do
    for id, nodes in pairs(match) do
      local node = type(nodes) == "table" and nodes[1] or nodes
      out[#out + 1] = {
        kind = query.captures[id],
        name = vim.treesitter.get_node_text(node, bufnr),
      }
    end
  end
  return out
end

--- workspace/symbol, raw. entity.fields keeps only a symbol whose name is
--- strictly equal to the entity's; reporting every result is what exposes
--- the case where jdtls answers but never with that exact name.
local function query_symbols(client, name)
  local fired, captured = await(function(resolve)
    local ok, sent = pcall(client.request, client, "workspace/symbol", { query = name }, function(err, results)
      resolve(err, results)
    end)
    if not ok or sent == false then
      resolve("request refused by the client", nil)
    end
  end)
  if not fired then
    return nil, "timeout"
  end
  return { err = captured[1], results = captured[2] }, nil
end

--- Layer 1: the java treesitter parser, without which nothing else runs.
local function check_treesitter()
  local ok = pcall(vim.treesitter.query.parse, "java", "(interface_declaration) @i")
  if ok then
    health.ok("java treesitter parser available")
  else
    health.error("java treesitter parser missing", {
      "Install it: :TSInstall java",
    })
  end
  return ok
end

--- Layer 2: the language server. entity.fields looks it up by the name
--- "jdtls" exactly, so a client attached under any other name is invisible
--- to the plugin however healthy it looks in :LspInfo.
local function check_jdtls()
  local clients = vim.lsp.get_clients({ name = "jdtls" })
  if #clients > 0 then
    health.ok(string.format("jdtls attached (%d client(s))", #clients))
    return clients[1]
  end

  local others = {}
  for _, client in ipairs(vim.lsp.get_clients()) do
    others[#others + 1] = client.name
  end

  if #others == 0 then
    health.error("no jdtls client", {
      "No LSP client is running at all.",
      "Without it entity.fields returns immediately with ok=false:",
      "completion offers neither fields nor conditions.",
    })
  else
    health.error("no client named 'jdtls'", {
      "Running clients: " .. table.concat(others, ", "),
      "entity.lua looks the server up with",
      "vim.lsp.get_clients({ name = 'jdtls' }): a Java server registered",
      "under a different name is never found.",
    })
  end
  return nil
end

--- Layers 4 to 6, per entity: symbol lookup, entity buffer, declaration.
local function check_entity_source(client, entity_name)
  local response, err = query_symbols(client, entity_name)
  if err == "timeout" then
    health.error(string.format("workspace/symbol(%s): no answer after %dms", entity_name, TIMEOUT_MS), {
      "jdtls is probably still indexing the project.",
      "Retry once :LspInfo reports the server as ready.",
    })
    return
  end

  if response.err then
    health.error(string.format("workspace/symbol(%s) failed", entity_name), {
      vim.inspect(response.err),
    })
    return
  end

  local results = response.results or {}
  if #results == 0 then
    health.error(string.format("workspace/symbol(%s): 0 result", entity_name), {
      "jdtls knows no symbol by that name.",
      "Either indexing is unfinished, or the entity lives outside the",
      "indexed project.",
    })
    return
  end

  local exact
  local names = {}
  for _, symbol in ipairs(results) do
    names[#names + 1] = tostring(symbol.name)
    if symbol.name == entity_name and not exact then
      exact = symbol
    end
  end

  if not exact then
    health.error(string.format("workspace/symbol(%s): no exact name match", entity_name), {
      string.format("%d result(s) returned: %s", #results, table.concat(names, ", ")),
      "entity.lua keeps a symbol only when symbol.name equals the entity",
      "name exactly, so none of these is used.",
    })
    return
  end

  health.ok(string.format("workspace/symbol(%s): %d result(s), exact match found", entity_name, #results))

  local uri = exact.location and exact.location.uri
  if not uri then
    health.error(string.format("%s: matching symbol carries no location.uri", entity_name))
    return
  end

  health.info("  uri: " .. uri)
  if uri:match("^jdt://") then
    health.warn("  the entity comes from a jar, not from a source file", {
      "Its content is not readable as a plain buffer: field extraction",
      "will fail.",
    })
  end

  local uri_ok, entity_bufnr = pcall(vim.uri_to_bufnr, uri)
  if not uri_ok or not entity_bufnr then
    health.error(string.format("%s: uri_to_bufnr failed", entity_name))
    return
  end

  local load_ok = pcall(vim.fn.bufload, entity_bufnr)
  if not load_ok or not vim.api.nvim_buf_is_loaded(entity_bufnr) then
    health.error(string.format("%s: the entity's buffer could not be loaded", entity_name))
    return
  end

  local found
  local listing = {}
  for _, decl in ipairs(declarations(entity_bufnr)) do
    listing[#listing + 1] = string.format("%s %s", decl.kind, decl.name)
    if decl.name == entity_name then
      found = decl
    end
  end

  if not found then
    health.error(string.format("%s: no declaration by that name in the file", entity_name), {
      "Declarations present: " .. (next(listing) and table.concat(listing, ", ") or "none"),
    })
    return
  end

  if found.kind ~= "class" then
    health.error(string.format("%s is declared as a %s, not a class", entity_name, found.kind), {
      "entity.lua's CLASS_QUERY only matches class_declaration:",
      "find_class_body returns nil, extract_fields returns nil, and",
      "entity.fields answers ok=false — permanently.",
    })
    return
  end

  local super = superclass_of(entity_bufnr, entity_name)
  if super then
    health.warn(string.format("%s extends %s", entity_name, super), {
      "extract_fields only walks field_declaration nodes that are direct",
      "children of this class's body: fields inherited from a",
      "@MappedSuperclass parent are never seen — neither suggested nor",
      "accepted when typed by hand.",
    })
  end
end

--- Layer 7: the result the completion source actually consumes.
local function check_fields(entity_name)
  entity.invalidate(entity_name)

  local fired, captured = await(function(resolve)
    entity.fields(entity_name, function(fields, ok)
      resolve(fields, ok)
    end)
  end)

  if not fired then
    health.error(string.format("entity.fields(%s): no answer after %dms", entity_name, TIMEOUT_MS))
    return
  end

  local fields, ok = captured[1] or {}, captured[2]

  if not ok then
    health.error(string.format("entity.fields(%s): ok=false", entity_name), {
      "The field list could NOT be established. The parser then disables",
      "property validation: completion offers no field and no condition,",
      "only And / Or / OrderBy.",
    })
    return
  end

  if #fields == 0 then
    health.error(string.format("entity.fields(%s): ok=true but 0 field", entity_name), {
      "The class was found and holds no persistable field of its own.",
      "This empty list IS cached until the entity's file is written.",
      "Likely causes: every field inherited from a parent class, or all",
      "of them static/transient.",
    })
    return
  end

  health.ok(string.format("entity.fields(%s): %d field(s)", entity_name, #fields))
  for _, field in ipairs(fields) do
    local annotations = field.annotations or {}
    health.info(string.format(
      "  %s %s%s",
      field.java_type,
      field.name,
      next(annotations) and ("  @" .. table.concat(annotations, " @")) or ""
    ))
  end
end

function M.check()
  health.start("spring-data.nvim")

  if not check_treesitter() then
    return
  end

  local client = check_jdtls()

  health.start("Repositories in loaded buffers")

  local buffers = java_buffers()
  if #buffers == 0 then
    health.warn("no Java buffer loaded", {
      "Open the repository you want to diagnose, then run this check",
      "again — it reads loaded buffers, not the current window.",
    })
    return
  end

  local entities = {}
  local order = {}
  for _, bufnr in ipairs(buffers) do
    local entity_name = entity.resolve_entity_name(bufnr)
    if entity_name then
      health.ok(string.format(
        "%s -> %s",
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t"),
        entity_name
      ))
      if not entities[entity_name] then
        entities[entity_name] = true
        order[#order + 1] = entity_name
      end
    end
  end

  if #order == 0 then
    health.warn(string.format("no repository among the %d Java buffer(s) loaded", #buffers), {
      "The source stays disabled: the plugin only activates on an",
      "interface extending a type whose name ends in Repository, with an",
      "explicit generic argument.",
    })
    return
  end

  if not client then
    health.info("jdtls missing: field resolution not probed")
    return
  end

  for _, entity_name in ipairs(order) do
    health.start("Entity " .. entity_name)
    check_entity_source(client, entity_name)
    check_fields(entity_name)
  end
end

return M
