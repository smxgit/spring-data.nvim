-- Tests for entity.lua, the only module that needs a real Neovim: it runs
-- treesitter over actual Java buffers.
--
-- jdtls is NOT needed. The inheritance walk takes its class resolver as a
-- parameter — jdtls in production, a fixture map here — which is what
-- makes the hierarchy logic testable without a language server.
--
-- Run with: nvim --headless -l tests/run_nvim.lua
local t = require("harness")
local entity = require("spring-data.entity")
local internal = entity.internal

local FIXTURES = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/fixtures/"

--- Loads a fixture into a buffer and returns its number.
local function fixture(name)
  local bufnr = vim.fn.bufadd(FIXTURES .. name .. ".java")
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].filetype = "java"
  return bufnr
end

--- Resolver over the fixtures: maps a simple class name to its buffer, or
--- nil when the class has no fixture — which stands for a class jdtls
--- can't reach (living in a jar, or not indexed yet).
local function fixture_resolver(class_name, callback)
  local path = FIXTURES .. class_name .. ".java"
  if vim.fn.filereadable(path) == 0 then
    callback(nil)
    return
  end
  callback(fixture(class_name))
end

--- Field names in order, for concise assertions.
local function names(fields)
  local out = {}
  for _, field in ipairs(fields) do
    out[#out + 1] = field.name
  end
  return out
end

--- Runs the walk synchronously: fixture_resolver never defers.
local function collect(class_name)
  local captured
  internal.collect_fields(class_name, fixture_resolver, function(fields, ok, visited)
    captured = { fields = fields, ok = ok, visited = visited }
  end)
  return captured
end

t.describe("resolve_entity_name", function()
  t.it("reads the first generic argument of a *Repository", function()
    t.eq(entity.resolve_entity_name(fixture("UserRepository")), "UserEntity")
  end)

  t.it("returns nil on a buffer that isn't a repository", function()
    t.eq(entity.resolve_entity_name(fixture("UserEntity")), nil)
  end)
end)

t.describe("extract_class", function()
  t.it("reads fields, class annotations and superclass", function()
    local info = internal.extract_class(fixture("UserEntity"), "UserEntity")
    t.eq(names(info.fields), { "name", "age" })
    t.eq(info.annotations, { "Entity", "Data" })
    t.eq(info.superclass, "BaseEntity")
  end)

  t.it("keeps the type and annotations of each field", function()
    local info = internal.extract_class(fixture("UserEntity"), "UserEntity")
    t.eq(info.fields[1], {
      name = "name",
      java_type = "String",
      annotations = { "Column(unique = true)" },
    })
    t.eq(info.fields[2].java_type, "int")
  end)

  t.it("drops static and transient fields", function()
    local info = internal.extract_class(fixture("UserEntity"), "UserEntity")
    for _, field in ipairs(info.fields) do
      t.truthy(field.name ~= "serialVersionUID", "static field leaked")
      t.truthy(field.name ~= "scratch", "transient field leaked")
    end
  end)

  t.it("reports no superclass when the class has none", function()
    local info = internal.extract_class(fixture("LoneEntity"), "LoneEntity")
    t.eq(info.superclass, nil)
    t.eq(names(info.fields), { "label" })
  end)

  t.it("returns nil for a record, distinct from an empty class", function()
    t.eq(internal.extract_class(fixture("PointRecord"), "PointRecord"), nil)
  end)

  t.it("returns nil when the class isn't in the buffer", function()
    t.eq(internal.extract_class(fixture("LoneEntity"), "Absent"), nil)
  end)
end)

t.describe("is_persistable", function()
  t.it("accepts @MappedSuperclass and @Entity", function()
    t.eq(internal.is_persistable({ "MappedSuperclass" }), true)
    t.eq(internal.is_persistable({ "Entity" }), true)
  end)

  t.it("ignores annotation arguments", function()
    t.eq(internal.is_persistable({ 'Table(name = "users")', "Entity" }), true)
  end)

  t.it("rejects a plain class", function()
    t.eq(internal.is_persistable({}), false)
    t.eq(internal.is_persistable({ "Data", "Getter" }), false)
  end)
end)

t.describe("collect_fields", function()
  t.it("walks the whole chain and marks it complete", function()
    local got = collect("UserEntity")
    t.eq(got.ok, true)
    -- own fields first, then each ancestor in order
    t.eq(names(got.fields), { "name", "age", "id", "createdAt", "version" })
  end)

  t.it("terminates on a class with no superclass", function()
    local got = collect("LoneEntity")
    t.eq(got.ok, true)
    t.eq(names(got.fields), { "label" })
  end)

  t.it("drops the state of a non-annotated parent but keeps walking", function()
    -- OrderEntity -> PlainHelper (plain) -> Auditable (@MappedSuperclass)
    local got = collect("OrderEntity")
    t.eq(got.ok, true)
    t.eq(names(got.fields), { "reference", "version" })
  end)

  t.it("lets a redeclared field shadow the inherited one", function()
    local got = collect("ShadowEntity")
    t.eq(got.ok, true)
    t.eq(names(got.fields), { "version" })
    -- the child's String wins over Auditable's Long
    t.eq(got.fields[1].java_type, "String")
  end)

  t.it("returns own fields with ok=false when a parent can't be resolved", function()
    local got = collect("OrphanEntity")
    t.eq(got.ok, false)
    t.eq(names(got.fields), { "title" })
  end)

  t.it("reports ok=false when the root itself can't be resolved", function()
    local got = collect("NoSuchEntity")
    t.eq(got.ok, false)
    t.eq(names(got.fields), {})
  end)

  t.it("reports every buffer visited, for cache invalidation", function()
    local got = collect("UserEntity")
    t.eq(#got.visited, 3)
  end)
end)

t.describe("merge_fields", function()
  t.it("keeps the first declaration of a name", function()
    local merged = internal.merge_fields({
      { name = "version", java_type = "String" },
      { name = "id", java_type = "Integer" },
      { name = "version", java_type = "Long" },
    })
    t.eq(names(merged), { "version", "id" })
    t.eq(merged[1].java_type, "String")
  end)

  t.it("preserves order", function()
    local merged = internal.merge_fields({
      { name = "a" }, { name = "b" }, { name = "c" },
    })
    t.eq(names(merged), { "a", "b", "c" })
  end)
end)
