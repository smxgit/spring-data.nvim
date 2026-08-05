-- Resolves a Spring Data repository's entity and extracts its fields.
-- The only module that depends on both treesitter and jdtls.
local M = {}

--- Treesitter query isolating the first generic argument of an interface
--- extending a type whose name ends in "Repository".
---
--- The java parser exposes `extends_interfaces` on recent versions and
--- `super_interfaces` on older ones; the query tolerates both by not
--- constraining the intermediate node.
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

--- Name of a repository's entity, or nil if the buffer isn't one.
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

--- True if the buffer contains an interface extending a *Repository.
function M.is_repository(bufnr)
  return M.resolve_entity_name(bufnr) ~= nil
end

-- Field cache, indexed by entity name. Invalidated on BufWritePost of the
-- entity's file, via setup_autocmds.
--
-- `uri_index` maps a BUFFER NUMBER (not a path) to the entity it holds:
-- `args.file` from a BufWritePost autocmd reflects however the buffer was
-- opened as-is — relative if opened via a fuzzy finder or a relative
-- path — while the URI jdtls returns is always absolute. The two strings
-- therefore almost never matched, and invalidation never fired. A buffer
-- number is stable and independent of any textual path representation.
local cache = {}
local uri_index = {}

-- In-flight `M.fields` requests by entity name: two concurrent requests
-- for the same entity share a single workspace/symbol request instead of
-- firing two, and both get resolved from the one response.
local pending = {}

--- Treesitter query locating a class by its simple name and body.
--- The name is filtered afterwards (strict equality with the entity being
--- looked up): the query itself matches any class, including nested ones
--- (an @Embeddable composite key, for instance), but since a simple class
--- name is unique within a Java file, filtering by equality unambiguously
--- isolates the right class's body.
local CLASS_QUERY = [[
(class_declaration
  name: (identifier) @name
  body: (class_body) @body)
]]

--- Body (class_body) of the class named `entity_name`, or nil if not
--- found in the tree.
local function find_class_body(root, bufnr, entity_name)
  local query_ok, query = pcall(vim.treesitter.query.parse, "java", CLASS_QUERY)
  if not query_ok then
    return nil
  end

  for _, match in query:iter_matches(root, bufnr, 0, -1) do
    local name_text, body_node
    for id, nodes in pairs(match) do
      local node = type(nodes) == "table" and nodes[1] or nodes
      local capture = query.captures[id]
      if capture == "name" then
        name_text = vim.treesitter.get_node_text(node, bufnr)
      elseif capture == "body" then
        body_node = node
      end
    end
    if name_text == entity_name and body_node then
      return body_node
    end
  end

  return nil
end

--- Simple name of an annotation, with any arguments, stripped of package
--- qualification: "@jakarta.persistence.Id" becomes "Id",
--- "@Column(unique = true)" stays "Column(unique = true)".
---
--- parser.is_unique_field (Task 9) compares by strict equality against the
--- simple name (`annotation == "Id"`) and searches for the "Column" /
--- "unique" substrings for the second case: a fully-qualified annotation
--- (legal in Java, `@jakarta.persistence.Id`) would break both checks if
--- it weren't normalised here.
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

--- Extracts the fields declared directly in a `field_declaration`,
--- annotations and modifiers included.
local function fields_of_declaration(node, bufnr)
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
          -- A static or transient field isn't persisted: it must not be
          -- offered.
          skip = true
        end
      end
    elseif kind == "variable_declarator" then
      local name_node = child:field("name")[1]
      if name_node then
        names[#names + 1] = vim.treesitter.get_node_text(name_node, bufnr)
      end
    elseif java_type == nil then
      -- First child that's neither the modifiers nor a declarator: it's
      -- the type node (type_identifier, generic_type, etc.).
      java_type = vim.treesitter.get_node_text(child, bufnr)
    end
  end

  if skip or not java_type then
    return {}
  end

  -- `private String a, b;` declares several fields in a single
  -- field_declaration: one per declarator, sharing type and annotations.
  local out = {}
  for _, name in ipairs(names) do
    out[#out + 1] = { name = name, java_type = java_type, annotations = annotations }
  end
  return out
end

--- Extracts the fields of class `entity_name` in a Java buffer: name,
--- type and annotations. Annotations and modifiers (static, transient)
--- live in the `field_declaration`'s `modifiers` node — documentSymbol
--- wouldn't surface them, hence going through treesitter on the real
--- buffer.
---
--- Only walks the `field_declaration` direct children of this specific
--- class's body: an unbounded query would also match the fields of a
--- nested class (an @Embeddable composite key, for instance) and leak
--- them into completion suggestions.
---
--- Returns nil if class `entity_name` isn't found in the tree — distinct
--- from an empty list, which means "class found, zero persistable field"
--- and is a legitimate result to cache. nil must never be cached: it lets
--- a later call retry instead.
local function extract_fields(bufnr, entity_name)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "java")
  if not ok or not parser then
    return nil
  end

  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local body = find_class_body(tree:root(), bufnr, entity_name)
  if not body then
    return nil
  end

  local fields = {}
  for child in body:iter_children() do
    if child:type() == "field_declaration" then
      for _, field in ipairs(fields_of_declaration(child, bufnr)) do
        fields[#fields + 1] = field
      end
    end
  end

  return fields
end

--- Loads a URI's file into a buffer and extracts the fields of class
--- `entity_name`. Returns `nil` (never cached by the caller) if the
--- buffer could not be loaded — deleted file, virtual `jdt://` document
--- from a jar whose content isn't accessible as-is, etc. Also returns the
--- resolved `bufnr`: the caller needs it to index `uri_index` without
--- ever going back through a path.
local function fields_from_uri(uri, entity_name)
  local uri_ok, bufnr = pcall(vim.uri_to_bufnr, uri)
  if not uri_ok or not bufnr then
    return nil
  end

  local load_ok = pcall(vim.fn.bufload, bufnr)
  if not load_ok or not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil
  end

  return extract_fields(bufnr, entity_name), bufnr
end

--- Fetches an entity's fields, going through the cache.
--- jdtls locates the file via workspace/symbol, treesitter extracts its
--- content — documentSymbol wouldn't surface the annotations.
---
--- `callback(fields, ok)`. `ok` is false when the list could NOT be
--- established — jdtls not yet attached, workspace/symbol silent,
--- unreadable file — as opposed to an entity genuinely lacking any
--- persistable field, which yields an empty list with `ok` true. Both
--- cases produce the same empty list on the parser side, which then
--- disables validation (design doc §6); without this second return value,
--- the caller would confuse "no error found" with "verified", and would
--- offer signatures built on properties never checked against the entity.
function M.fields(entity_name, callback)
  if cache[entity_name] then
    callback(cache[entity_name], true)
    return
  end

  local waiters = pending[entity_name]
  if waiters then
    -- A request is already in flight for this entity: hook onto its
    -- response instead of firing a second one.
    waiters[#waiters + 1] = callback
    return
  end

  local clients = vim.lsp.get_clients({ name = "jdtls" })
  if #clients == 0 then
    callback({}, false)
    return
  end

  waiters = { callback }
  pending[entity_name] = waiters

  -- `waiters` identifies this specific request: if `M.invalidate` has in
  -- the meantime unhooked `pending[entity_name]` (because jdtls crashed
  -- or restarted without ever responding — the request will then never
  -- call back, and without this unhooking `pending[entity_name]` would
  -- stay occupied forever, blocking any further attempt), a late,
  -- orphaned response from this request still serves its own waiting
  -- callbacks, but touches neither the cache nor `pending`, which by then
  -- belong to a possible more recent request.
  local resolved = false
  local function resolve(fields, ok)
    -- Idempotent: the caller has two failure paths (send refused and
    -- error response) that could otherwise serve the same callbacks
    -- twice.
    if resolved then
      return
    end
    resolved = true
    fields = fields or {}
    if pending[entity_name] == waiters then
      pending[entity_name] = nil
      if ok then
        cache[entity_name] = fields
      end
    end
    for _, cb in ipairs(waiters) do
      cb(fields, ok)
    end
  end

  local function on_symbols(err, results)
    if err or not results or #results == 0 then
      resolve(nil, false)
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
      resolve(nil, false)
      return
    end

    local fields, bufnr = fields_from_uri(uri, entity_name)
    if fields == nil then
      -- Extraction failed (file not found, unreadable jdt:// URI, class
      -- absent from the tree…): never cache this result, so a later call
      -- retries instead of staying stuck on an empty result forever — no
      -- BufWritePost would ever invalidate it.
      resolve(nil, false)
      return
    end

    uri_index[bufnr] = entity_name
    resolve(fields, true)
  end

  -- `pending` is already set: any exit that doesn't go through `resolve`
  -- would leave this entity mute for the rest of the session, and the
  -- exception would propagate up to `get_completions`, so on every
  -- keystroke. `Client:request` can raise (invalid handle, client
  -- shutting down) and can also respond `false` without ever calling the
  -- handler — both close the door the same way.
  local ok, sent = pcall(clients[1].request, clients[1], "workspace/symbol", { query = entity_name }, on_symbols)
  if not ok or sent == false then
    resolve(nil, false)
  end
end

--- Clears an entity's cache entry, or the whole cache if no name is given.
--- Also unhooks `pending`: an in-flight request that will never respond
--- (jdtls crashed or restarted) must not block later calls indefinitely —
--- `M.invalidate` is the recovery mechanism.
function M.invalidate(entity_name)
  if entity_name then
    cache[entity_name] = nil
    pending[entity_name] = nil
  else
    cache = {}
    uri_index = {}
    pending = {}
  end
end

--- Invalidates an entity's cache as soon as its file is saved.
function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("SpringDataEntityCache", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.java",
    callback = function(args)
      local entity_name = uri_index[args.buf]
      if entity_name then
        M.invalidate(entity_name)
      end
    end,
  })
end

return M
