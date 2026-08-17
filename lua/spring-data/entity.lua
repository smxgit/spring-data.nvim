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

-- Field cache, indexed by entity name. Invalidated on BufWritePost of any
-- file taking part in the entity's inheritance chain, via setup_autocmds.
--
-- `uri_index` maps a BUFFER NUMBER (not a path) to the SET of entities
-- whose field list was built from it: `args.file` from a BufWritePost
-- autocmd reflects however the buffer was opened as-is — relative if
-- opened via a fuzzy finder or a relative path — while the URI jdtls
-- returns is always absolute. The two strings therefore almost never
-- matched, and invalidation never fired. A buffer number is stable and
-- independent of any textual path representation.
--
-- A set rather than a single name because one buffer now feeds several
-- entities: a @MappedSuperclass parent is part of the chain of every
-- entity extending it, and saving it must invalidate all of them.
local cache = {}
local uri_index = {}

-- In-flight `M.fields` requests by entity name: two concurrent requests
-- for the same entity share a single walk instead of firing two, and both
-- get resolved from the one response.
local pending = {}

-- Depth limit on the inheritance walk. Java forbids cycles, but a stale
-- index or a malformed buffer must not be able to spin this forever, and
-- nothing useful lives ten levels up a JPA hierarchy.
local MAX_DEPTH = 10

--- Treesitter query locating a class by its simple name, capturing the
--- declaration node itself so annotations and `extends` can be read off
--- it. The name is filtered afterwards (strict equality with the class
--- being looked up): the query itself matches any class, including nested
--- ones (an @Embeddable composite key, for instance), but since a simple
--- class name is unique within a Java file, filtering by equality
--- unambiguously isolates the right class.
---
--- Only `class_declaration` is matched, on purpose: a record, an enum or
--- an interface has no persistable field state to contribute, and the
--- caller must be able to tell "not a class" from "class with no field".
local CLASS_QUERY = [[
(class_declaration
  name: (identifier) @name
  body: (class_body) @body) @class
]]

--- Simple name of an annotation, with any arguments, stripped of package
--- qualification: "@jakarta.persistence.Id" becomes "Id",
--- "@Column(unique = true)" stays "Column(unique = true)".
---
--- parser.is_unique_field compares by strict equality against the simple
--- name (`annotation == "Id"`) and searches for the "Column" / "unique"
--- substrings for the second case: a fully-qualified annotation (legal in
--- Java, `@jakarta.persistence.Id`) would break both checks if it weren't
--- normalised here.
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

--- Annotations carried by a declaration's `modifiers` node.
local function annotations_of(node, bufnr)
  local out = {}
  for child in node:iter_children() do
    if child:type() == "modifiers" then
      for modifier in child:iter_children() do
        local kind = modifier:type()
        if kind == "annotation" or kind == "marker_annotation" then
          local text = annotation_text(modifier, bufnr)
          if text then
            out[#out + 1] = text
          end
        end
      end
    end
  end
  return out
end

--- Simple name of the class in `extends`, or nil.
---
--- Reads the `superclass` child node rather than naming its field in the
--- query, the way resolve_entity_name already tolerates
--- extends_interfaces / super_interfaces: field names have moved across
--- java parser versions, and an unknown field name makes query.parse
--- raise rather than simply not match.
---
--- Generics and package qualification are stripped: `extends
--- AbstractPersistable<Long>` and `extends com.example.BaseEntity` both
--- yield the simple name, which is what workspace/symbol is queried with.
local function superclass_of(class_node, bufnr)
  for child in class_node:iter_children() do
    if child:type() == "superclass" then
      for sub in child:iter_children() do
        local kind = sub:type()
        if kind == "type_identifier" or kind == "scoped_type_identifier" or kind == "generic_type" then
          local text = vim.treesitter.get_node_text(sub, bufnr)
          -- generic_type keeps its arguments, scoped_type_identifier its
          -- package: both are cut back to the simple name.
          return text:gsub("<.*$", ""):match("([%w_]+)%s*$")
        end
      end
    end
  end
  return nil
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

--- Everything class `class_name` contributes to an entity's field list:
--- its own fields, its class-level annotations and the name of its
--- superclass. Annotations and modifiers (static, transient) live in the
--- `modifiers` node — documentSymbol wouldn't surface them, hence going
--- through treesitter on the real buffer.
---
--- Only walks the `field_declaration` direct children of this specific
--- class's body: an unbounded query would also match the fields of a
--- nested class (an @Embeddable composite key, for instance) and leak
--- them into completion suggestions.
---
--- Returns nil if `class_name` isn't found in the tree as a class — not
--- present at all, or declared as a record / enum / interface. Distinct
--- from a table with an empty `fields` list, which means "class found,
--- zero persistable field" and is a legitimate result to cache. nil must
--- never be cached: it lets a later call retry instead.
local function extract_class(bufnr, class_name)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "java")
  if not ok or not parser then
    return nil
  end

  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local query_ok, query = pcall(vim.treesitter.query.parse, "java", CLASS_QUERY)
  if not query_ok then
    return nil
  end

  for _, match in query:iter_matches(tree:root(), bufnr, 0, -1) do
    local name_text, body_node, class_node
    for id, nodes in pairs(match) do
      local node = type(nodes) == "table" and nodes[1] or nodes
      local capture = query.captures[id]
      if capture == "name" then
        name_text = vim.treesitter.get_node_text(node, bufnr)
      elseif capture == "body" then
        body_node = node
      elseif capture == "class" then
        class_node = node
      end
    end

    if name_text == class_name and body_node and class_node then
      local fields = {}
      for child in body_node:iter_children() do
        if child:type() == "field_declaration" then
          for _, field in ipairs(fields_of_declaration(child, bufnr)) do
            fields[#fields + 1] = field
          end
        end
      end
      return {
        fields = fields,
        annotations = annotations_of(class_node, bufnr),
        superclass = superclass_of(class_node, bufnr),
      }
    end
  end

  return nil
end

--- Does this class contribute its state to the entities extending it?
---
--- Per the Jakarta Persistence specification, the fields of a superclass
--- that is neither @Entity nor @MappedSuperclass are NOT persisted: such
--- a class is plain object-model infrastructure. Offering its fields
--- would suggest query methods Spring rejects at startup.
---
--- The chain is still walked through it — the spec allows
--- Entity -> non-entity -> MappedSuperclass — only its own state is
--- dropped.
local function is_persistable(annotations)
  for _, annotation in ipairs(annotations or {}) do
    local simple = annotation:match("^([%w_]+)")
    if simple == "MappedSuperclass" or simple == "Entity" then
      return true
    end
  end
  return false
end

--- Deduplicates by field name, keeping the FIRST occurrence.
---
--- The walk appends ancestors after the class's own fields, so "first
--- wins" is Java's shadowing rule: a field redeclared in a subclass hides
--- the inherited one, with the subclass's type.
local function merge_fields(collected)
  local seen = {}
  local out = {}
  for _, field in ipairs(collected) do
    if not seen[field.name] then
      seen[field.name] = true
      out[#out + 1] = field
    end
  end
  return out
end

--- Walks a class and its ancestors, gathering persistable fields.
---
--- `resolve(class_name, callback)` maps a simple class name to a loaded
--- buffer, or nil when it can't be reached. It is injected rather than
--- hardcoded: jdtls provides it in production, a fixture map in the
--- tests, which is what makes this walk testable without a language
--- server.
---
--- `callback(fields, ok, visited)`:
---   fields  own fields first, then each ancestor's, deduplicated
---   ok      true only if the WHOLE chain was resolved. A partial result
---           is still returned and still usable for suggestions, but the
---           caller must not cache it, nor build a full signature on a
---           list it knows to be incomplete.
---   visited buffer numbers that fed the list, for cache invalidation
local function collect_fields(class_name, resolve, callback)
  local collected = {}
  local visited = {}

  local function step(name, depth)
    resolve(name, function(bufnr)
      if not bufnr then
        callback(merge_fields(collected), false, visited)
        return
      end

      local info = extract_class(bufnr, name)
      if not info then
        callback(merge_fields(collected), false, visited)
        return
      end

      visited[#visited + 1] = bufnr

      -- The root is the entity itself: the repository already designates
      -- it, so its own state counts whatever it is annotated with. Only
      -- ancestors have to earn their fields.
      if depth == 0 or is_persistable(info.annotations) then
        for _, field in ipairs(info.fields) do
          collected[#collected + 1] = field
        end
      end

      if not info.superclass then
        callback(merge_fields(collected), true, visited)
        return
      end

      if depth + 1 >= MAX_DEPTH then
        callback(merge_fields(collected), false, visited)
        return
      end

      step(info.superclass, depth + 1)
    end)
  end

  step(class_name, 0)
end

--- Class resolver backed by jdtls: workspace/symbol locates the file,
--- which is then loaded as a buffer for treesitter to read.
---
--- Every failure path answers nil rather than raising: collect_fields
--- turns that into ok=false, which the caller reports as "incomplete" and
--- never caches.
local function jdtls_resolver(client)
  return function(class_name, callback)
    local answered = false
    local function answer(bufnr)
      -- `Client:request` can both raise and answer, so this guard keeps
      -- the walk from being resumed twice down two different branches.
      if answered then
        return
      end
      answered = true
      callback(bufnr)
    end

    local function on_symbols(err, results)
      if err or not results then
        answer(nil)
        return
      end

      for _, symbol in ipairs(results) do
        if symbol.name == class_name then
          local uri = symbol.location and symbol.location.uri
          if uri then
            local uri_ok, bufnr = pcall(vim.uri_to_bufnr, uri)
            if uri_ok and bufnr then
              -- A `jdt://` document from a jar has no readable content:
              -- bufload leaves the buffer empty, extract_class finds no
              -- class, and the chain is reported incomplete.
              local load_ok = pcall(vim.fn.bufload, bufnr)
              if load_ok and vim.api.nvim_buf_is_loaded(bufnr) then
                answer(bufnr)
                return
              end
            end
          end
        end
      end

      answer(nil)
    end

    local ok, sent = pcall(client.request, client, "workspace/symbol", { query = class_name }, on_symbols)
    if not ok or sent == false then
      answer(nil)
    end
  end
end

--- Fetches an entity's fields, going through the cache.
--- jdtls locates the files, treesitter extracts their content —
--- documentSymbol wouldn't surface the annotations.
---
--- `callback(fields, ok)`. `ok` is false when the list could NOT be
--- fully established — jdtls not yet attached, workspace/symbol silent,
--- unreadable file, or an ancestor that couldn't be reached — as opposed
--- to an entity genuinely lacking any persistable field, which yields an
--- empty list with `ok` true. Both cases produce the same empty list on
--- the parser side, which then disables validation (design doc §6);
--- without this second return value, the caller would confuse "no error
--- found" with "verified", and would offer signatures built on properties
--- never checked against the entity.
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
  local function resolve(fields, ok, visited)
    -- Idempotent: the walk has several failure paths that could otherwise
    -- serve the same callbacks twice.
    if resolved then
      return
    end
    resolved = true
    fields = fields or {}
    if pending[entity_name] == waiters then
      pending[entity_name] = nil
      if ok then
        cache[entity_name] = fields
        -- Only index buffers whose contribution was actually kept: a
        -- partial walk isn't cached, so there is nothing to invalidate.
        for _, bufnr in ipairs(visited or {}) do
          uri_index[bufnr] = uri_index[bufnr] or {}
          uri_index[bufnr][entity_name] = true
        end
      end
    end
    for _, cb in ipairs(waiters) do
      cb(fields, ok)
    end
  end

  local ok, err = pcall(collect_fields, entity_name, jdtls_resolver(clients[1]), resolve)
  if not ok then
    -- `pending` is already set: any exit that doesn't go through
    -- `resolve` would leave this entity mute for the rest of the session,
    -- and the exception would propagate up to `get_completions`, so on
    -- every keystroke.
    vim.schedule(function()
      vim.notify("spring-data: field resolution failed: " .. tostring(err), vim.log.levels.DEBUG)
    end)
    resolve({}, false, nil)
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

--- Invalidates an entity's cache as soon as a file its field list was
--- built from is saved — the entity's own file, or any @MappedSuperclass
--- ancestor it inherits fields from.
function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("SpringDataEntityCache", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.java",
    callback = function(args)
      local entities = uri_index[args.buf]
      if not entities then
        return
      end
      for entity_name in pairs(entities) do
        M.invalidate(entity_name)
      end
    end,
  })
end

--- Internals exposed for tests/entity_spec.lua, which exercises the
--- inheritance walk against Java fixtures without a language server.
M.internal = {
  extract_class = extract_class,
  is_persistable = is_persistable,
  merge_fields = merge_fields,
  collect_fields = collect_fields,
}

return M
