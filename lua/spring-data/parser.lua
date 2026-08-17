-- Parses a derived query method string, possibly incomplete.
--
-- This module is pure Lua: it never references `vim` and depends on
-- neither Neovim nor jdtls, which makes it testable under a bare
-- interpreter.
--
-- The pipeline reproduces PartTree. Splitting never consults the field
-- list: that only ever serves to validate the properties obtained.
local grammar = require("spring-data.grammar")

local M = {}

--- Splits `text` around `keyword`, the way PartTree.split does.
---
--- Reimplements KEYWORD_TEMPLATE = "(%s)(?=(\p{Lu}|\P{InBASIC_LATIN}))".
--- Lua has no lookahead, so checking that the keyword is followed by an
--- uppercase letter is done by hand. The \P{InBASIC_LATIN} class, aimed at
--- CJK identifiers, is deliberately left out — see design doc §5.5.
---
--- This casing rule, and only this rule, is what resolves the `andrew`
--- collision: in "andrewAge", And is followed by a lowercase `r`.
---
--- A leading empty segment is kept, as Pattern.split does on the Java
--- side; it's up to the caller to filter it out.
function M.split_on_keyword(text, keyword)
  local parts = {}
  local segment_start = 1
  local search_from = 1

  while true do
    local s, e = text:find(keyword, search_from, true)
    if not s then
      break
    end
    local next_char = text:sub(e + 1, e + 1)
    if next_char:match("^%u") then
      parts[#parts + 1] = text:sub(segment_start, s - 1)
      segment_start = e + 1
      search_from = e + 1
    else
      search_from = s + 1
    end
  end

  parts[#parts + 1] = text:sub(segment_start)
  return parts
end

--- True if `s` ends with `suffix`.
function M.ends_with(s, suffix)
  return #s >= #suffix and s:sub(-#suffix) == suffix
end

--- Reproduces java.beans.Introspector.decapitalize.
--- A string whose first two characters are uppercase is returned
--- unchanged, which preserves acronyms ("URL" stays "URL").
function M.decapitalize(s)
  if s == "" then
    return s
  end
  if #s > 1 and s:sub(1, 1):match("%u") and s:sub(2, 2):match("%u") then
    return s
  end
  return s:sub(1, 1):lower() .. s:sub(2)
end

--- Strips the Ignor(ing|e)Case pattern from a part and reports its
--- presence. Must be called BEFORE type detection, the way Part does:
--- detectAndSetIgnoreCase precedes Type.fromProperty.
function M.strip_ignore_case(part)
  for _, keyword in ipairs(grammar.ignore_case) do
    local s, e = part:find(keyword, 1, true)
    if s then
      return part:sub(1, s - 1) .. part:sub(e + 1), true
    end
  end
  return part, false
end

--- Classifies a Java type into one of the filtering categories.
--- Any unrecognised type falls under "unknown": enum, related entity,
--- custom type. Only List, Set and Collection yield "collection".
function M.categorize(java_type)
  local base = java_type:match("^([%w_%.]+)") or java_type
  base = base:match("([%w_]+)$") or base

  for _, container in ipairs(grammar.collection_types) do
    if base == container and java_type:find("<", 1, true) then
      return "collection"
    end
  end

  return grammar.categories[base] or "unknown"
end

--- Extracts the First/Top limiting clause from the subject's middle group.
--- Reproduces LIMITED_QUERY_TEMPLATE, which enforces the order Distinct
--- then First/Top and only applies to the "query" category.
local function parse_limiting(middle, category)
  if category ~= "query" then
    return nil
  end

  local rest = middle
  if rest:sub(1, #grammar.distinct) == grammar.distinct then
    rest = rest:sub(#grammar.distinct + 1)
  end

  for _, keyword in ipairs(grammar.limiting) do
    if rest:sub(1, #keyword) == keyword then
      local digits = rest:sub(#keyword + 1):match("^%d*")
      if digits == "" then
        return 1
      end
      return tonumber(digits)
    end
  end

  return nil
end

--- Parses the subject and returns the remainder, i.e. the predicate.
---
--- Reproduces PREFIX_TEMPLATE:
---   ^(find|read|…|remove)((\p{Lu}.*?))??By
--- The middle group being optional and reluctant, we first try without it
--- — By glued to the introducer — then with it, requiring an uppercase
--- first character and keeping the first By encountered.
---
--- Returns nil if no introducer matches; the caller then treats the whole
--- string as a predicate, the way PartTree does.
---
--- The raw middle group is kept in `middle`: it's what the still-being-
--- typed fragment in the "subject" state ("Dist" in "findDist") is derived
--- from, which none of the already-normalised fields can provide.
function M.parse_subject(source)
  for _, intro in ipairs(grammar.introducers) do
    if source:sub(1, #intro.keyword) == intro.keyword then
      local rest = source:sub(#intro.keyword + 1)
      local s, e = rest:find("By", 1, true)

      local middle, predicate, has_by
      if s == 1 then
        middle, predicate, has_by = "", rest:sub(e + 1), true
      elseif s and rest:sub(1, 1):match("%u") then
        middle, predicate, has_by = rest:sub(1, s - 1), rest:sub(e + 1), true
      else
        middle, predicate, has_by = rest, nil, false
      end

      return {
        introducer = intro.keyword,
        category = intro.category,
        distinct = middle:find(grammar.distinct, 1, true) ~= nil,
        max_results = parse_limiting(middle, intro.category),
        has_by = has_by,
        middle = middle,
      }, predicate
    end
  end

  return nil
end

--- Determines a part's condition type and extracts its raw property.
---
--- Reproduces Part.Type.fromProperty: walks grammar.types IN ORDER, first
--- type whose alias satisfies endsWith. It's the order, not a longest-
--- match rule, that gives the right result: "ageLessThanEqual" does not
--- end with "LessThan", so LESS_THAN is passed over in favour of
--- LESS_THAN_EQUAL.
---
--- With no match, SIMPLE_PROPERTY and the whole part, matching
--- fromProperty's final `return SIMPLE_PROPERTY`.
function M.detect_type(part)
  for _, type_entry in ipairs(grammar.types) do
    for _, keyword in ipairs(type_entry.keywords) do
      if M.ends_with(part, keyword) then
        return type_entry, part:sub(1, #part - #keyword)
      end
    end
  end

  return grammar.default_type, part
end

--- Strips AllIgnor(ing|e)Case from the whole predicate.
--- Must precede any splitting, the way Predicate.detectAndSetAllIgnoreCase
--- does.
local function strip_all_ignore_case(predicate)
  for _, keyword in ipairs(grammar.all_ignore_case) do
    local s, e = predicate:find(keyword, 1, true)
    if s then
      return predicate:sub(1, s - 1) .. predicate:sub(e + 1), true
    end
  end
  return predicate, false
end

--- Filters out empty segments produced by a split, the way
--- filter(StringUtils::hasText) does on the Java side.
local function compact(segments)
  local out = {}
  for _, segment in ipairs(segments) do
    if segment ~= "" then
      out[#out + 1] = segment
    end
  end
  return out
end

local function find_field(fields, property)
  for _, field in ipairs(fields) do
    if field.name == property then
      return field
    end
  end
  return nil
end

--- True if the condition type accepts the field's category.
local function accepts_category(type_entry, category, java_type)
  if type_entry.requires_nullable and grammar.primitives[java_type] then
    return false
  end
  if type_entry.accepts == "all" then
    return true
  end
  for _, accepted in ipairs(type_entry.accepts) do
    if accepted == category then
      return true
    end
  end
  return false
end

--- Builds the parameters a predicate implies.
--- BETWEEN, the only two-argument type, produces <property>Start and
--- <property>End. IN and NOT_IN produce a Collection of the boxed type,
--- since a Java generic can't take a primitive.
local function build_params(type_entry, property, field)
  if type_entry.args == 0 then
    return {}
  end

  local java_type = field and field.java_type or "Object"

  if type_entry.name == "IN" or type_entry.name == "NOT_IN" then
    local boxed = grammar.boxed[java_type] or java_type
    return { { name = property, java_type = "Collection<" .. boxed .. ">" } }
  end

  if type_entry.accepts ~= "all" and #type_entry.accepts == 1 and type_entry.accepts[1] == "string" then
    java_type = "String"
  end

  if type_entry.args == 2 then
    return {
      { name = property .. "Start", java_type = java_type },
      { name = property .. "End", java_type = java_type },
    }
  end

  return { { name = property, java_type = java_type } }
end

--- Parses the sort clause.
--- Reproduces OrderBySource: splitting after Asc or Desc followed by an
--- uppercase letter, direction optional at the end of a block.
local function parse_order_by(clause)
  local blocks = {}
  local start = 1
  local i = 1

  while i <= #clause do
    for _, direction in ipairs(grammar.directions) do
      local at = i - #direction + 1
      if at >= 1 and clause:sub(at, i) == direction then
        local next_char = clause:sub(i + 1, i + 1)
        if next_char:match("^%u") then
          blocks[#blocks + 1] = clause:sub(start, i)
          start = i + 1
        end
      end
    end
    i = i + 1
  end
  blocks[#blocks + 1] = clause:sub(start)

  local out = {}
  for _, block in ipairs(compact(blocks)) do
    local direction = nil
    for _, candidate in ipairs(grammar.directions) do
      if M.ends_with(block, candidate) then
        direction = candidate
        block = block:sub(1, #block - #candidate)
        break
      end
    end
    out[#out + 1] = { property = M.decapitalize(block), direction = direction }
  end
  return out
end

--- Validates sort properties against the field list.
---
--- Spring resolves each sort property via PropertyPath exactly like
--- predicate properties: "findByNameOrderByBogusAsc" raises a
--- PropertyReferenceException at context startup. Without this check, the
--- source would offer a signature that keeps the application from
--- starting, which design doc §7 forbids.
---
--- An empty property ("findByNameOrderByAsc") is reported regardless of
--- the field list: the fault is structural, not a resolution question, so
--- it stays detectable even when validation is degraded.
local function validate_order_by(order_by, fields, errors)
  for _, entry in ipairs(order_by) do
    if entry.property == "" then
      errors[#errors + 1] = {
        code = "missing_order_property",
        message = "missing sort property before " .. (entry.direction or "the end"),
      }
    elseif #fields > 0 and not find_field(fields, entry.property) then
      errors[#errors + 1] = {
        code = "unknown_property",
        message = "unknown sort property: " .. entry.property,
      }
    end
  end
end

--- Portion of the subject's middle group not yet recognised as either
--- Distinct or First/Top: what the user is currently typing ("Dist" in
--- "findDist", "Fir" in "findDistinctFir").
local function subject_residual(middle, category)
  local rest = middle or ""

  if rest:sub(1, #grammar.distinct) == grammar.distinct then
    rest = rest:sub(#grammar.distinct + 1)
  end

  if category == "query" then
    for _, keyword in ipairs(grammar.limiting) do
      if rest:sub(1, #keyword) == keyword then
        rest = rest:sub(#keyword + 1):gsub("^%d+", "")
        break
      end
    end
  end

  return rest
end

--- Determines the terminal state, i.e. what's expected at the current
--- position. This is what sets this parser apart from PartTree, which
--- only ever handles complete strings.
local function terminal_state(source, subject, result, has_order_by)
  if not subject or not subject.has_by then
    return "subject"
  end

  -- Fix: a user who just typed OrderBy is waiting for a sort property.
  -- split_on_keyword rejects this case because OrderBy, right at the end
  -- of the string, is followed by no character at all — hence no
  -- uppercase letter — so has_order_by stays false (the same rule as for
  -- "andrewAge", here applied at a position where it shouldn't apply).
  if M.ends_with(source, grammar.order_by) then
    return "order_property"
  end

  if has_order_by then
    if #result.order_by == 0 then
      return "order_property"
    end
    return "order_direction"
  end

  for _, connector in ipairs(grammar.connectors) do
    if M.ends_with(source, connector) then
      return "expect_property"
    end
  end

  if #result.predicates == 0 then
    return "expect_property"
  end

  local last = result.predicates[#result.predicates]
  if last.property == "" then
    return "expect_property"
  end
  if last.explicit_keyword then
    return "after_condition"
  end
  return "after_property"
end

--- Fragment still being typed at the current position: the FINAL portion
--- of `source` that a suggestion must REPLACE rather than extend. Empty
--- string once everything typed is already resolved, in which case
--- suggestions are appended as before.
---
--- Without it, typing a single character of a field or keyword made the
--- property unresolvable and made every useful suggestion disappear.
---
--- The fragment is always a literal suffix of `source`: that's what lets
--- the consumer count characters alone. The two cases where the retained
--- property is NOT a suffix of the source — an explicit keyword follows it
--- (after_condition state), or an Ignor(ing|e)Case was stripped from the
--- middle — therefore return the empty string.
local function terminal_fragment(source, subject, result, fields, all_ignore_case)
  local state = result.state

  if state == "subject" then
    if not subject then
      return source
    end
    return subject_residual(subject.middle, subject.category)
  end

  -- Property validation is disabled without a field list (§6): nothing
  -- then distinguishes a fragment from a completed property, and guessing
  -- would mean offering anything at all. We abstain.
  if #fields == 0 or all_ignore_case then
    return ""
  end

  if state == "after_property" then
    local last = result.predicates[#result.predicates]
    if not last or last.field or last.ignore_case or last.property == "" then
      return ""
    end
    return source:sub(-#last.property)
  end

  if state == "order_direction" then
    local last = result.order_by[#result.order_by]
    if not last or last.direction or last.property == "" or find_field(fields, last.property) then
      return ""
    end
    return source:sub(-#last.property)
  end

  return ""
end

--- Parses a derived query method string, possibly incomplete.
---
--- `fields` is a list of { name, java_type, annotations }. It may be
--- empty: property validation is then disabled rather than producing
--- noise. It NEVER factors into splitting.
---
--- Contract on waiting states. In the "expect_property" and
--- "order_property" states, the last entry of `predicates` (and the
--- parameter or error that may go with it) can be a FRAGMENT of what the
--- user is still typing, not a completed property. This is not a bug to
--- fix in the data: an And, Or or OrderBy right at the end of a string is
--- undecidable from the string alone — a complete field named "…And", or
--- a connector not yet followed by a property? — and settling it would
--- require consulting `fields` at split time, which this module never does
--- (see above). Splitting therefore follows the same rule as
--- PartTree/split_on_keyword: the keyword stays attached to the text if
--- it isn't followed by an uppercase letter, including when it's followed
--- by nothing at all. Consumers MUST rely on `state` to know whether the
--- last predicate is trustworthy, never on the content of `predicates`
--- alone.
---
--- `fragment` completes this contract: it's the suffix of `source` the
--- user is still typing (see terminal_fragment). It's the empty string as
--- soon as all typed text is resolved.
function M.parse(source, fields)
  fields = fields or {}

  local result = {
    subject = nil,
    predicates = {},
    order_by = {},
    params = {},
    state = "subject",
    fragment = "",
    errors = {},
  }

  local subject, predicate_source = M.parse_subject(source)
  result.subject = subject

  if not subject or not subject.has_by then
    result.state = "subject"
    result.fragment = terminal_fragment(source, subject, result, fields, false)
    return result
  end

  local predicate, all_ignore_case = strip_all_ignore_case(predicate_source)

  local order_segments = M.split_on_keyword(predicate, grammar.order_by)
  if #order_segments > 2 then
    result.errors[#result.errors + 1] = {
      code = "duplicate_order_by",
      message = "OrderBy can only appear once",
    }
  end

  local has_order_by = #order_segments > 1
  if has_order_by then
    result.order_by = parse_order_by(order_segments[2])
    validate_order_by(result.order_by, fields, result.errors)
  end

  local or_segments = compact(M.split_on_keyword(order_segments[1], "Or"))
  local first = true

  for _, or_segment in ipairs(or_segments) do
    local and_segments = compact(M.split_on_keyword(or_segment, "And"))

    for and_index, part in ipairs(and_segments) do
      local connector
      if first then
        connector = nil
        first = false
      elseif and_index > 1 then
        connector = "And"
      else
        connector = "Or"
      end

      local stripped, ignore_case = M.strip_ignore_case(part)
      local type_entry, raw_property = M.detect_type(stripped)
      local property = M.decapitalize(raw_property)
      local field = find_field(fields, property)

      if not type_entry.jpa then
        result.errors[#result.errors + 1] = {
          code = "unsupported_keyword",
          message = type_entry.name .. " is not supported by Spring Data JPA",
        }
      end

      if #fields > 0 and not field and property ~= "" then
        result.errors[#result.errors + 1] = {
          code = "unknown_property",
          message = "unknown property: " .. property,
        }
      end

      -- A keyword JPA doesn't support at all makes no sense to evaluate
      -- against the field's type: that would report the same fault twice,
      -- the second time for the wrong reason (the field has nothing to do
      -- with it). Only a valid JPA keyword can be incompatible with a type.
      if field and type_entry.jpa then
        local category = M.categorize(field.java_type)
        if not accepts_category(type_entry, category, field.java_type) then
          result.errors[#result.errors + 1] = {
            code = "incompatible_type",
            message = type_entry.name .. " does not apply to " .. field.java_type,
          }
        end
      end

      -- Explicit IgnoreCase on a field that isn't a String: JPA refuses at
      -- startup. Part.detectAndSetIgnoreCase gives the ALWAYS type, which
      -- JpaQueryCreator.upperIfIgnoreCase turns into an Assert.state —
      -- "Unable to ignore case of int types, the property 'age' must
      -- reference a String".
      --
      -- AllIgnor(ing|e)Case is deliberately excluded: PartTree.Predicate
      -- propagates it to parts as WHEN_POSSIBLE, a branch that only
      -- applies upper() when the type allows it and never raises.
      -- Reporting both forms the same way would produce an error for a
      -- string Spring accepts.
      if field and ignore_case and M.categorize(field.java_type) ~= "string" then
        result.errors[#result.errors + 1] = {
          code = "incompatible_type",
          message = "IgnoreCase does not apply to " .. field.java_type,
        }
      end

      result.predicates[#result.predicates + 1] = {
        property = property,
        field = field,
        type = type_entry,
        ignore_case = ignore_case or all_ignore_case,
        connector = connector,
        explicit_keyword = raw_property ~= stripped,
      }

      for _, param in ipairs(build_params(type_entry, property, field)) do
        result.params[#result.params + 1] = param
      end
    end
  end

  result.state = terminal_state(source, subject, result, has_order_by)
  result.fragment = terminal_fragment(source, subject, result, fields, all_ignore_case)
  return result
end

--- True if the field is annotated @Id or @Column(unique = true).
local function is_unique_field(field)
  if not field then
    return false
  end
  for _, annotation in ipairs(field.annotations or {}) do
    if annotation == "Id" then
      return true
    end
    if annotation:find("Column", 1, true) and annotation:find("unique", 1, true) then
      local value = annotation:match("unique%s*=%s*(%a+)")
      if value == "true" then
        return true
      end
    end
  end
  return false
end

--- The single return type deduced from the method's shape.
---
--- Optional<T> is reserved for queries whose maximum cardinality is
--- guaranteed to be one. The official return-type table is explicit:
--- "Expects the query method to return one result at most. More than one
--- result triggers an IncorrectResultSizeDataAccessException." The
--- "no result" case is already covered by List<T>, which returns an empty
--- list and never null.
local function deduced_type(result, entity_name)
  local subject = result.subject

  if subject.max_results == 1 then
    return "Optional<" .. entity_name .. ">"
  end
  if subject.max_results and subject.max_results > 1 then
    return "List<" .. entity_name .. ">"
  end

  if #result.predicates == 1 then
    local predicate = result.predicates[1]
    if predicate.type.name == "SIMPLE_PROPERTY" and is_unique_field(predicate.field) then
      return "Optional<" .. entity_name .. ">"
    end
  end

  return "List<" .. entity_name .. ">"
end

--- Every return type the method may legitimately carry, best first.
---
--- Two shapes leave a genuine choice open, and Spring settles neither:
---
---   deleteBy / removeBy   void or the delete count, both documented as
---                         "returning either no result (void) or the
---                         delete count".
---   streamBy              the deduced type or Stream<T>. `stream` is one
---                         of six interchangeable general query keywords
---                         — PartTree's QUERY_PATTERN accepts them
---                         indifferently and the documentation's own
---                         streaming example is spelled
---                         readAllByFirstnameNotNull() — so the keyword
---                         suggests the intent without imposing the type.
---
--- Both are offered side by side rather than fixed in configuration: the
--- decision belongs to the call site, not to the project. The same
--- repository legitimately wants a Stream in one method, consumed inside
--- a transaction, and a plain List in the next.
---
--- The deduced type stays first: it is what the method's own shape says.
function M.return_types(result, entity_name)
  local subject = result.subject

  if not subject then
    return { "List<" .. entity_name .. ">" }
  end

  if subject.category == "count" then
    return { "long" }
  end
  if subject.category == "exists" then
    return { "boolean" }
  end
  if subject.category == "delete" then
    return { "void", "long" }
  end

  local deduced = deduced_type(result, entity_name)
  if subject.introducer == "stream" then
    return { deduced, "Stream<" .. entity_name .. ">" }
  end
  return { deduced }
end

--- The most likely return type: the first candidate.
function M.return_type(result, entity_name)
  return M.return_types(result, entity_name)[1]
end

--- True if `typed` is a prefix of `label`, aside from the case of the
--- first letter. Field labels come back in lowerCamelCase ("name") while
--- keywords are capitalised ("Containing"), whereas the typed fragment
--- carries the source's own casing ("Na"): only the first letter can
--- legitimately differ.
local function prefix_matches(typed, label)
  if typed == "" then
    return true
  end
  if #typed > #label then
    return false
  end
  if typed:sub(1, 1):lower() ~= label:sub(1, 1):lower() then
    return false
  end
  return typed:sub(2) == label:sub(2, #typed)
end

--- Turns the terminal state into suggestions, type filtering applied.
---
--- Types whose `jpa` is false are never offered: REGEX and EXISTS would
--- raise "Unsupported keyword" at startup, NEAR and WITHIN are out of
--- scope for v1.
---
--- The neutral set for unknown types isn't hardcoded here: it follows from
--- grammar.types' `accepts` column.
---
--- Each suggestion carries a `replace_length`: how many characters its
--- label replaces AT THE END of the typed text. Zero — the case for
--- anything already resolved — means "append". This is what makes
--- completing a partial token possible: on "findByNameCont", Containing
--- replaces the four characters of "Cont" to yield
--- "findByNameContaining". The consumer therefore has no string surgery
--- of its own to redo.
---
--- The fragment is used to FILTER what gets suggested, never to re-split
--- the string: `result` is the only splitting that happens, and it never
--- consults the fields. Breaking the fragment down into "field + rest" is
--- a suggestion-selection choice, which this function already makes from
--- `fields`.
function M.suggestions(result, fields)
  fields = fields or {}
  local fragment = result.fragment or ""
  local out = {}

  --- Only emits the suggestion if `typed` is a prefix of it.
  local function add(typed, label, kind, detail)
    if prefix_matches(typed, label) then
      out[#out + 1] = { label = label, kind = kind, detail = detail, replace_length = #typed }
    end
  end

  local function add_fields(typed)
    for _, field in ipairs(fields) do
      add(typed, field.name, "property", field.java_type)
    end
  end

  --- Conditions compatible with `field`'s type.
  local function add_conditions(typed, field)
    local category = M.categorize(field.java_type)
    for _, type_entry in ipairs(grammar.types) do
      if type_entry.jpa and accepts_category(type_entry, category, field.java_type) then
        for _, keyword in ipairs(type_entry.keywords) do
          add(typed, keyword, "keyword", type_entry.name)
        end
      end
    end
  end

  local function add_connectors(typed)
    for _, connector in ipairs(grammar.connectors) do
      add(typed, connector, "connector", "connects two predicates")
    end
    add(typed, grammar.order_by, "connector", "sort clause")
  end

  --- Remainder of the fragment beyond `field`'s name, or nil if the
  --- fragment doesn't extend this field. Used to offer what can follow a
  --- property whose only its end is left to type: "NameCont" extends
  --- "name" with the remainder "Cont".
  local function tail_of(field)
    if #fragment <= #field.name or not prefix_matches(field.name, fragment) then
      return nil
    end
    return fragment:sub(#field.name + 1)
  end

  local state = result.state

  if state == "subject" then
    local subject = result.subject
    local category = subject and subject.category or "query"
    if not subject then
      for _, intro in ipairs(grammar.introducers) do
        add(fragment, intro.keyword, "modifier", intro.category)
      end
    end
    -- Distinct and First/Top each appear only once: offering them again
    -- once already present could only produce a "findDistinctDistinct"
    -- that Spring rejects.
    if not (subject and subject.distinct) then
      add(fragment, grammar.distinct, "modifier", "distinct results")
    end
    if category == "query" and not (subject and subject.max_results) then
      for _, keyword in ipairs(grammar.limiting) do
        add(fragment, keyword, "modifier", "limits the number of results")
      end
    end
    add(fragment, "By", "modifier", "introduces the predicate")
    return out
  end

  -- Neither of these two states ever has a fragment: the connector or
  -- OrderBy was just typed, the property that follows is still entirely
  -- to be written.
  if state == "expect_property" or state == "order_property" then
    add_fields(fragment)
    return out
  end

  if state == "order_direction" then
    local sort = result.order_by[#result.order_by]

    if fragment == "" then
      -- A direction already in place closes the block: only a new sort
      -- property can follow. Offering a second one would give
      -- "OrderByAgeAscAsc", whose second property is empty.
      if not (sort and sort.direction) then
        for _, direction in ipairs(grammar.directions) do
          add("", direction, "direction", "sort direction")
        end
      end
      add_fields("")
      return out
    end

    add_fields(fragment)
    for _, field in ipairs(fields) do
      local tail = tail_of(field)
      if tail then
        for _, direction in ipairs(grammar.directions) do
          add(tail, direction, "direction", "sort direction")
        end
      end
    end
    return out
  end

  local last = result.predicates[#result.predicates]
  local field = last and last.field

  if state == "after_property" then
    if fragment == "" then
      if field then
        add_conditions("", field)
      end
      add_connectors("")
      return out
    end

    -- Property still incomplete: offer on one hand the fields it's a
    -- start of, on the other what can follow a field it extends. A
    -- fragment matching nothing offers nothing.
    add_fields(fragment)
    for _, candidate in ipairs(fields) do
      local tail = tail_of(candidate)
      if tail then
        add_conditions(tail, candidate)
        add_connectors(tail)
      end
    end
    return out
  end

  -- after_condition
  if field and M.categorize(field.java_type) == "string" then
    add("", "IgnoreCase", "keyword", "case-insensitive comparison")
  end
  add_connectors("")

  return out
end

return M
