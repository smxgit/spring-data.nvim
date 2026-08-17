-- blink.cmp source for Spring Data derived query methods.
local parser = require("spring-data.parser")
local entity = require("spring-data.entity")

local M = {}

function M.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = M })
end

--- Active only in a Java buffer whose interface extends a *Repository.
function M:enabled()
  if vim.bo.filetype ~= "java" then
    return false
  end
  return entity.is_repository(0)
end

--- Method fragment already typed, to the left of the cursor.
--- Walks back to the start of the identifier, stopping at anything that
--- can't be part of a method name.
local function current_prefix(ctx)
  local line = ctx.line or ""
  local col = ctx.cursor and ctx.cursor[2] or #line
  local before = line:sub(1, col)
  return before:match("([%a%d_]+)$") or ""
end

--- Uppercases the first letter: the inverse of parser.decapitalize for the
--- common case. Java fields are declared in lowerCamelCase
--- (`private String name`), so `suggestions()` returns their name as-is
--- ("name") — without this reshaping, a property suggestion would
--- produce an invalid Java identifier ("findByname" instead of
--- "findByName").
local function capitalize(s)
  if s == "" then
    return s
  end
  return s:sub(1, 1):upper() .. s:sub(2)
end

--- Full text to offer for a suggestion.
---
--- `replace_length` says how many characters at the END of the typed text
--- the label replaces: zero for what simply gets appended (the common
--- case), the length of the token being typed otherwise. This is how
--- "findByNameCont" + Containing yields "findByNameContaining" rather than
--- "findByNameContContaining", and "fin" + find yields "find" rather than
--- the absurd "finfind". The parser alone knows where the fragment starts,
--- so no string surgery is redone here.
---
--- "property" suggestions use the field's name as declared (lowercase
--- first letter): it has to be capitalised to form a valid method
--- segment.
local function fragment_text(prefix, suggestion)
  local candidate = suggestion.label
  if suggestion.kind == "property" then
    candidate = capitalize(candidate)
  end

  local kept = #prefix - (suggestion.replace_length or 0)
  if kept < 0 then
    kept = 0
  end

  return prefix:sub(1, kept) .. candidate
end

--- Builds the LuaSnip snippet for the full signature.
--- Tabstops sit on the parameter names, to allow renaming them right
--- after insertion.
local function build_snippet(method_name, return_type, params)
  local rendered = {}
  for index, param in ipairs(params) do
    rendered[#rendered + 1] = string.format(
      "%s ${%d:%s}",
      param.java_type,
      index,
      param.name
    )
  end
  return string.format(
    "%s %s(%s);$0",
    return_type,
    method_name,
    table.concat(rendered, ", ")
  )
end

--- States in which the full signature can be offered: never before a
--- property has been selected, so as not to reproduce Spring Tools' bare
--- `findBy` (issue spring-projects/spring-tools#1014).
---
--- The last predicate can be a FRAGMENT in the waiting states
--- (`findByNameAnd`, `findByNameOrderBy` leave the final token attached
--- to the property, with an `unknown_property` error): it's `result.state`
--- that distinguishes a complete predicate from a fragment still being
--- typed, not inspecting the last predicate — never bypass this gate by
--- reading `result.predicates` directly.
local COMPLETE_STATES = {
  after_property = true,
  after_condition = true,
  order_direction = true,
}

--- True if the full signature can be offered.
---
--- `fields_ok` is the decisive condition: without a field list, the
--- parser disables property validation (§6) and `errors` is therefore
--- empty because NOTHING was checked, not because the method is correct.
--- Conflating the two would offer "List<UserEntity>
--- findByNameCont(Object nameCont);" while jdtls isn't attached yet.
--- Fragments, on the other hand, stay offered: they claim nothing.
local function offers_signature(result, fields_ok)
  return fields_ok == true
    and COMPLETE_STATES[result.state] == true
    and #result.predicates > 0
    and #result.errors == 0
end

--- Effective options: those from `require("spring-data").setup{}`,
--- overridden by those declared on the blink provider.
---
--- `M.new` only receives the latter — the provider config's `opts` key —
--- almost always absent. Without this merge, an option passed to
--- `setup{}` never reached `parser.return_type`: it was written to
--- `spring-data.opts` and read by nobody.
---
--- Merged by hand rather than via `vim.tbl_extend`: this module must stay
--- loadable under a bare interpreter so its pure functions remain
--- testable without Neovim.
local function options(provider_opts)
  local merged = {}
  for key, value in pairs(require("spring-data").opts or {}) do
    merged[key] = value
  end
  for key, value in pairs(provider_opts or {}) do
    merged[key] = value
  end
  return merged
end

function M:get_completions(ctx, callback)
  local cancelled = false
  local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()

  local entity_name = entity.resolve_entity_name(bufnr)
  if not entity_name then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return function() end
  end

  local prefix = current_prefix(ctx)

  -- The repository's buffer is what resolves the entity's package: an
  -- unqualified `Document` is either imported explicitly or declared in
  -- this very package, and that is the only thing telling it apart from
  -- the homonyms jdtls returns from every jar on the classpath.
  entity.fields(entity_name, bufnr, function(fields, fields_ok)
    -- `entity.fields` responds asynchronously (workspace/symbol to
    -- jdtls): if the user kept typing or the context changed in the
    -- meantime, blink.cmp already called the cancellation function
    -- returned below — `cancelled` then keeps this late callback from
    -- invoking `callback` with a stale result, computed against a
    -- `prefix` that no longer matches what's on screen.
    if cancelled then
      return
    end

    local result = parser.parse(prefix, fields)
    local items = {}

    -- Fragments: properties, keywords, connectors, directions.
    for _, suggestion in ipairs(parser.suggestions(result, fields)) do
      local label = fragment_text(prefix, suggestion)
      items[#items + 1] = {
        label = label,
        filterText = label,
        insertText = label,
        labelDetails = { description = suggestion.detail },
        kind = suggestion.kind == "property" and 5 or 14, -- Field / Keyword
        sortText = string.format("%02d%s", suggestion.kind == "property" and 1 or 2, label),
      }
    end

    -- Full signature: never before a property has been selected, so as
    -- not to reproduce Spring Tools' bare `findBy` (issue #1014).
    if offers_signature(result, fields_ok) then
      local return_type = parser.return_type(result, entity_name, options(self.opts))
      items[#items + 1] = {
        label = prefix,
        filterText = prefix,
        labelDetails = { description = return_type },
        kind = 2, -- Method
        insertTextFormat = 2, -- Snippet
        insertText = build_snippet(prefix, return_type, result.params),
        sortText = "00" .. prefix,
        documentation = {
          kind = "markdown",
          value = string.format(
            "```java\n%s %s(%s);\n```",
            return_type,
            prefix,
            (function()
              local parts = {}
              for _, param in ipairs(result.params) do
                parts[#parts + 1] = param.java_type .. " " .. param.name
              end
              return table.concat(parts, ", ")
            end)()
          ),
        },
      }
    end

    callback({
      items = items,
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
  end)

  return function()
    cancelled = true
  end
end

--- Pure functions of this module, exposed for tests/source_spec.lua.
--- blink.cmp only ever calls new/enabled/get_completions: these have no
--- other reason to be public, but they carry two of the three defects the
--- final review found here and must therefore be pinned.
M.internal = {
  current_prefix = current_prefix,
  capitalize = capitalize,
  fragment_text = fragment_text,
  build_snippet = build_snippet,
  offers_signature = offers_signature,
  options = options,
}

return M
