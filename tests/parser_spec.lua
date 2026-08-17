local t = require("harness")
local parser = require("spring-data.parser")

t.describe("parser › split_on_keyword", function()
  t.it("splits when the keyword is followed by an uppercase letter", function()
    t.eq(parser.split_on_keyword("NameAndAge", "And"), { "Name", "Age" })
  end)

  t.it("does not split when followed by lowercase", function()
    t.eq(parser.split_on_keyword("andrewAge", "And"), { "andrewAge" })
    t.eq(parser.split_on_keyword("AndrewAge", "And"), { "AndrewAge" })
  end)

  t.it("only splits on valid occurrences", function()
    t.eq(parser.split_on_keyword("AndrewAndAge", "And"), { "Andrew", "Age" })
  end)

  t.it("does not split on a keyword at the end of the string", function()
    t.eq(parser.split_on_keyword("NameAnd", "And"), { "NameAnd" })
  end)

  t.it("produces a leading empty segment like Java's split", function()
    t.eq(parser.split_on_keyword("AndId", "And"), { "", "Id" })
  end)

  t.it("handles multiple occurrences", function()
    t.eq(parser.split_on_keyword("AAndBAndC", "And"), { "A", "B", "C" })
  end)

  t.it("returns the string unchanged when the keyword is absent", function()
    t.eq(parser.split_on_keyword("Name", "And"), { "Name" })
  end)
end)

t.describe("parser › ends_with", function()
  t.it("recognises a suffix", function()
    t.eq(parser.ends_with("ageBetween", "Between"), true)
  end)

  t.it("rejects a non-suffix", function()
    t.eq(parser.ends_with("ageLessThanEqual", "LessThan"), false)
    t.eq(parser.ends_with("ageLessThanEqual", "LessThanEqual"), true)
  end)

  t.it("rejects a suffix longer than the string", function()
    t.eq(parser.ends_with("Is", "IsNotNull"), false)
  end)
end)

t.describe("parser › decapitalize", function()
  t.it("lowercases the first letter", function()
    t.eq(parser.decapitalize("Name"), "name")
  end)

  t.it("preserves acronyms like Introspector.decapitalize", function()
    t.eq(parser.decapitalize("URL"), "URL")
    t.eq(parser.decapitalize("ID"), "ID")
  end)

  t.it("leaves an empty string unchanged", function()
    t.eq(parser.decapitalize(""), "")
  end)

  t.it("leaves an already-lowercase string unchanged", function()
    t.eq(parser.decapitalize("name"), "name")
  end)
end)

t.describe("parser › strip_ignore_case", function()
  t.it("strips IgnoreCase and reports it", function()
    local part, found = parser.strip_ignore_case("nameContainingIgnoreCase")
    t.eq(part, "nameContaining")
    t.eq(found, true)
  end)

  t.it("strips the IgnoringCase variant", function()
    local part, found = parser.strip_ignore_case("nameIgnoringCase")
    t.eq(part, "name")
    t.eq(found, true)
  end)

  t.it("reports nothing when the pattern is absent", function()
    local part, found = parser.strip_ignore_case("nameContaining")
    t.eq(part, "nameContaining")
    t.eq(found, false)
  end)
end)

t.describe("parser › categorize", function()
  t.it("classifies known types", function()
    t.eq(parser.categorize("String"), "string")
    t.eq(parser.categorize("int"), "numeric")
    t.eq(parser.categorize("LocalDate"), "temporal")
    t.eq(parser.categorize("Boolean"), "boolean")
  end)

  t.it("recognises generic containers", function()
    t.eq(parser.categorize("List<Order>"), "collection")
    t.eq(parser.categorize("Set<String>"), "collection")
    t.eq(parser.categorize("Collection<Long>"), "collection")
  end)

  t.it("classifies enums and related entities as unknown", function()
    t.eq(parser.categorize("Status"), "unknown")
    t.eq(parser.categorize("AddressEntity"), "unknown")
  end)

  t.it("ignores generic parameters of a non-container type", function()
    t.eq(parser.categorize("Optional<String>"), "unknown")
  end)
end)

t.describe("parser › parse_subject", function()
  t.it("recognises a minimal subject", function()
    local subject, predicate = parser.parse_subject("findByName")
    t.eq(subject.introducer, "find")
    t.eq(subject.category, "query")
    t.eq(subject.distinct, false)
    t.eq(subject.max_results, nil)
    t.eq(subject.has_by, true)
    t.eq(predicate, "Name")
  end)

  t.it("recognises every introducer category", function()
    t.eq(parser.parse_subject("countByName").category, "count")
    t.eq(parser.parse_subject("existsByName").category, "exists")
    t.eq(parser.parse_subject("deleteByName").category, "delete")
    t.eq(parser.parse_subject("removeByName").category, "delete")
    t.eq(parser.parse_subject("streamByName").category, "query")
  end)

  t.it("accepts a domain type between the introducer and By", function()
    local subject, predicate = parser.parse_subject("findUserByName")
    t.eq(subject.introducer, "find")
    t.eq(predicate, "Name")
  end)

  t.it("detects Distinct", function()
    local subject = parser.parse_subject("findDistinctByName")
    t.eq(subject.distinct, true)
  end)

  t.it("detects First and Top without a number as a limit of 1", function()
    t.eq(parser.parse_subject("findFirstByName").max_results, 1)
    t.eq(parser.parse_subject("findTopByName").max_results, 1)
  end)

  t.it("detects First and Top with a number", function()
    t.eq(parser.parse_subject("findFirst10ByName").max_results, 10)
    t.eq(parser.parse_subject("findTop5ByName").max_results, 5)
  end)

  t.it("accepts Distinct before First, in the order Spring imposes", function()
    local subject = parser.parse_subject("findDistinctTop5ByName")
    t.eq(subject.distinct, true)
    t.eq(subject.max_results, 5)
  end)

  t.it("does not apply the limit to count, exists and delete categories", function()
    t.eq(parser.parse_subject("countByName").max_results, nil)
    t.eq(parser.parse_subject("existsByName").max_results, nil)
    t.eq(parser.parse_subject("deleteByName").max_results, nil)
  end)

  t.it("detects Distinct on count despite no limiting", function()
    local subject = parser.parse_subject("countDistinctByName")
    t.eq(subject.distinct, true)
    t.eq(subject.max_results, nil)
  end)

  t.it("reports a still-incomplete subject", function()
    local subject, predicate = parser.parse_subject("findDistinct")
    t.eq(subject.has_by, false)
    t.eq(predicate, nil)
  end)

  t.it("keeps the first By, the middle group being reluctant", function()
    local _, predicate = parser.parse_subject("findByStandByFlag")
    t.eq(predicate, "StandByFlag")
  end)

  t.it("rejects a lowercase by, like the Java pattern does", function()
    local subject, predicate = parser.parse_subject("findbyName")
    t.eq(subject.has_by, false)
    t.eq(predicate, nil)
  end)

  t.it("returns nil if no introducer matches", function()
    t.eq(parser.parse_subject("fetchByName"), nil)
  end)
end)

t.describe("parser › detect_type", function()
  local function name_of(part)
    local ty = parser.detect_type(part)
    return ty.name
  end

  t.it("falls back to SIMPLE_PROPERTY with no keyword", function()
    local ty, property = parser.detect_type("name")
    t.eq(ty.name, "SIMPLE_PROPERTY")
    t.eq(property, "name")
  end)

  t.it("distinguishes GreaterThanEqual from GreaterThan", function()
    t.eq(name_of("ageGreaterThan"), "GREATER_THAN")
    t.eq(name_of("ageGreaterThanEqual"), "GREATER_THAN_EQUAL")
  end)

  t.it("distinguishes LessThanEqual from LessThan", function()
    t.eq(name_of("ageLessThan"), "LESS_THAN")
    t.eq(name_of("ageLessThanEqual"), "LESS_THAN_EQUAL")
  end)

  t.it("prefers IS_NOT_NULL over IS_NULL, as ALL's order requires", function()
    t.eq(name_of("nameNotNull"), "IS_NOT_NULL")
    t.eq(name_of("nameIsNotNull"), "IS_NOT_NULL")
    t.eq(name_of("nameNull"), "IS_NULL")
  end)

  t.it("prefers NOT_LIKE over LIKE", function()
    t.eq(name_of("nameNotLike"), "NOT_LIKE")
    t.eq(name_of("nameLike"), "LIKE")
  end)

  t.it("prefers NOT_IN over IN", function()
    t.eq(name_of("ageNotIn"), "NOT_IN")
    t.eq(name_of("ageIn"), "IN")
  end)

  t.it("prefers NOT_CONTAINING over CONTAINING", function()
    t.eq(name_of("nameNotContaining"), "NOT_CONTAINING")
    t.eq(name_of("nameContaining"), "CONTAINING")
  end)

  t.it("recognises every CONTAINING alias and extracts the property", function()
    local ty1, prop1 = parser.detect_type("nameContaining")
    t.eq(ty1.name, "CONTAINING")
    t.eq(prop1, "name")

    local ty2, prop2 = parser.detect_type("nameIsContaining")
    t.eq(ty2.name, "CONTAINING")
    t.eq(prop2, "name")

    local ty3, prop3 = parser.detect_type("nameContains")
    t.eq(ty3.name, "CONTAINING")
    t.eq(prop3, "name")
  end)

  t.it("recognises every STARTING_WITH alias", function()
    local ty1, prop1 = parser.detect_type("nameStartingWith")
    t.eq(ty1.name, "STARTING_WITH")
    t.eq(prop1, "name")

    local ty2, prop2 = parser.detect_type("nameStartsWith")
    t.eq(ty2.name, "STARTING_WITH")
    t.eq(prop2, "name")

    local ty3, prop3 = parser.detect_type("nameIsStartingWith")
    t.eq(ty3.name, "STARTING_WITH")
    t.eq(prop3, "name")
  end)

  t.it("strips the suffix to yield the raw property", function()
    local _, property = parser.detect_type("ageBetween")
    t.eq(property, "age")
  end)

  t.it("recognises types not supported by JPA so they can be reported", function()
    t.eq(name_of("nameRegex"), "REGEX")
    t.eq(name_of("nameMatches"), "REGEX")
  end)

  t.it("prefers NEGATING_SIMPLE_PROPERTY over SIMPLE_PROPERTY", function()
    t.eq(name_of("nameNot"), "NEGATING_SIMPLE_PROPERTY")
    t.eq(name_of("nameIs"), "SIMPLE_PROPERTY")
    t.eq(name_of("nameEquals"), "SIMPLE_PROPERTY")
  end)

  t.it("recognises BETWEEN and its two arguments", function()
    local ty = parser.detect_type("ageBetween")
    t.eq(ty.name, "BETWEEN")
    t.eq(ty.args, 2)
  end)

  t.it("handles the edge case: a part that IS exactly a keyword", function()
    local ty, property = parser.detect_type("Between")
    t.eq(ty.name, "BETWEEN")
    t.eq(property, "")
  end)
end)

local FIELDS = {
  { name = "id", java_type = "Long", annotations = { "Id" } },
  { name = "name", java_type = "String", annotations = {} },
  { name = "email", java_type = "String", annotations = { "Column(unique = true)" } },
  { name = "age", java_type = "int", annotations = {} },
  { name = "createdAt", java_type = "LocalDateTime", annotations = {} },
  { name = "active", java_type = "boolean", annotations = {} },
  { name = "orders", java_type = "List<Order>", annotations = { "OneToMany" } },
  { name = "andrew", java_type = "String", annotations = {} },
  -- Fields whose name ends in a splitting keyword, to cover the same
  -- collision as "andrew" but for And/Or/OrderBy at the end of a string.
  { name = "logicalAnd", java_type = "String", annotations = {} },
  { name = "sortOrderBy", java_type = "String", annotations = {} },
  { name = "isOr", java_type = "String", annotations = {} },
}

local function names_of(list, key)
  local out = {}
  for _, item in ipairs(list) do
    out[#out + 1] = item[key]
  end
  return out
end

t.describe("parser › parse", function()
  t.it("parses a simple predicate", function()
    local r = parser.parse("findByName", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.predicates[1].property, "name")
    t.eq(r.predicates[1].type.name, "SIMPLE_PROPERTY")
    t.eq(r.predicates[1].connector, nil)
    t.eq(r.params, { { name = "name", java_type = "String" } })
    t.eq(r.errors, {})
  end)

  t.it("parses two predicates joined by And", function()
    local r = parser.parse("findByNameAndAge", FIELDS)
    t.eq(names_of(r.predicates, "property"), { "name", "age" })
    t.eq(r.predicates[2].connector, "And")
    t.eq(r.params, {
      { name = "name", java_type = "String" },
      { name = "age", java_type = "int" },
    })
  end)

  t.it("parses two predicates joined by Or", function()
    local r = parser.parse("findByNameOrAge", FIELDS)
    t.eq(names_of(r.predicates, "property"), { "name", "age" })
    t.eq(r.predicates[2].connector, "Or")
  end)

  t.it("does not split a field whose name contains And", function()
    local r = parser.parse("findByAndrewAge", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.predicates[1].property, "andrewAge")
    t.eq(r.errors[1].code, "unknown_property")
  end)

  t.it("correctly splits a colliding field followed by a real And", function()
    local r = parser.parse("findByAndrewAndAge", FIELDS)
    t.eq(names_of(r.predicates, "property"), { "andrew", "age" })
    t.eq(r.errors, {})
  end)

  -- Regression: splitting NEVER consults the field list (see the plan's
  -- constraints). "findByLogicalAnd" is therefore undecidable from the
  -- string alone — And still being typed, or a complete field named
  -- "logicalAnd"? — and split_on_keyword settles it the way PartTree
  -- does: and/Or/OrderBy right at the end of a string, not followed by an
  -- uppercase letter, stay attached to the text. When the matching field
  -- genuinely exists, this choice is the right one: the complete property
  -- is found with no error.
  t.it("recognises a field whose name ends in And", function()
    local r = parser.parse("findByLogicalAnd", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.predicates[1].property, "logicalAnd")
    t.eq(r.errors, {})
  end)

  t.it("recognises a field whose name ends in OrderBy", function()
    local r = parser.parse("findBySortOrderBy", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.predicates[1].property, "sortOrderBy")
    t.eq(r.errors, {})
  end)

  t.it("recognises a field whose name ends in Or", function()
    local r = parser.parse("findByIsOr", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.predicates[1].property, "isOr")
    t.eq(r.errors, {})
  end)

  t.it("generates two parameters for Between", function()
    local r = parser.parse("findByAgeBetween", FIELDS)
    t.eq(r.params, {
      { name = "ageStart", java_type = "int" },
      { name = "ageEnd", java_type = "int" },
    })
  end)

  t.it("generates no parameter for zero-argument conditions", function()
    t.eq(parser.parse("findByNameIsNull", FIELDS).params, {})
    t.eq(parser.parse("findByActiveTrue", FIELDS).params, {})
    t.eq(parser.parse("findByOrdersIsEmpty", FIELDS).params, {})
  end)

  t.it("types In's parameter as a Collection of the wrapper", function()
    t.eq(parser.parse("findByAgeIn", FIELDS).params, {
      { name = "age", java_type = "Collection<Integer>" },
    })
    t.eq(parser.parse("findByNameIn", FIELDS).params, {
      { name = "name", java_type = "Collection<String>" },
    })
  end)

  t.it("detects IgnoreCase without disturbing the type", function()
    local r = parser.parse("findByNameContainingIgnoreCase", FIELDS)
    t.eq(r.predicates[1].type.name, "CONTAINING")
    t.eq(r.predicates[1].property, "name")
    t.eq(r.predicates[1].ignore_case, true)
  end)

  t.it("strips AllIgnoreCase before any splitting", function()
    local r = parser.parse("findByNameAllIgnoreCaseAndAge", FIELDS)
    t.eq(names_of(r.predicates, "property"), { "name", "age" })
  end)

  t.it("parses a sort with a direction", function()
    local r = parser.parse("findByNameOrderByAgeDesc", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.order_by, { { property = "age", direction = "Desc" } })
  end)

  t.it("parses a sort with no explicit direction", function()
    local r = parser.parse("findByNameOrderByAge", FIELDS)
    t.eq(r.order_by, { { property = "age", direction = nil } })
  end)

  t.it("parses a sort over several properties", function()
    local r = parser.parse("findByNameOrderByAgeAscIdDesc", FIELDS)
    t.eq(r.order_by, {
      { property = "age", direction = "Asc" },
      { property = "id", direction = "Desc" },
    })
  end)

  t.it("reports a duplicate OrderBy", function()
    local r = parser.parse("findByNameOrderByAgeOrderByName", FIELDS)
    t.eq(r.errors[1].code, "duplicate_order_by")
  end)

  t.it("reports a keyword not supported by JPA", function()
    local r = parser.parse("findByNameRegex", FIELDS)
    t.eq(r.errors[1].code, "unsupported_keyword")
    -- A non-JPA keyword must not also be reported as incompatible with the
    -- field's type: that would be a second, factually wrong error (the
    -- problem isn't "name"'s type).
    t.eq(#r.errors, 1)
  end)

  t.it("reports a condition incompatible with the field's type", function()
    local r = parser.parse("findByAgeContaining", FIELDS)
    t.eq(r.errors[1].code, "incompatible_type")
  end)

  t.it("reports an unknown property", function()
    local r = parser.parse("findByUnknownField", FIELDS)
    t.eq(r.errors[1].code, "unknown_property")
  end)

  -- JpaQueryCreator.upperIfIgnoreCase: "Unable to ignore case of int
  -- types, the property 'age' must reference a String". Without this
  -- check, the source used to offer a signature that keeps the
  -- application from starting.
  t.it("reports IgnoreCase on a non-text field", function()
    local r = parser.parse("findByAgeIgnoreCase", FIELDS)
    t.eq(r.errors, { { code = "incompatible_type", message = "IgnoreCase does not apply to int" } })
  end)

  t.it("accepts IgnoreCase on a text field", function()
    t.eq(parser.parse("findByNameIgnoreCase", FIELDS).errors, {})
    t.eq(parser.parse("findByNameContainingIgnoreCase", FIELDS).errors, {})
  end)

  -- AllIgnor(ing|e)Case gives parts the WHEN_POSSIBLE IgnoreCaseType, and
  -- that branch of upperIfIgnoreCase only applies upper() when the type
  -- allows it: it never raises. Reporting it would be a false error.
  t.it("does not report AllIgnoreCase on a non-text field", function()
    t.eq(parser.parse("findByNameAndAgeAllIgnoreCase", FIELDS).errors, {})
  end)

  t.it("reports an unknown sort property", function()
    local r = parser.parse("findByNameOrderByBogusAsc", FIELDS)
    t.eq(r.errors, { { code = "unknown_property", message = "unknown sort property: bogus" } })
  end)

  t.it("reports a missing sort property", function()
    local r = parser.parse("findByNameOrderByAsc", FIELDS)
    t.eq(r.errors[1].code, "missing_order_property")
    -- Structural fault: detectable even without a field list.
    t.eq(parser.parse("findByNameOrderByAsc", {}).errors[1].code, "missing_order_property")
  end)

  t.it("validates every sort property of a multi-key clause", function()
    t.eq(parser.parse("findByNameOrderByAgeAscIdDesc", FIELDS).errors, {})
    t.eq(#parser.parse("findByNameOrderByAgeAscBogusDesc", FIELDS).errors, 1)
  end)

  t.it("does not validate sort properties without a field list", function()
    t.eq(parser.parse("findByNameOrderByBogusAsc", {}).errors, {})
  end)

  t.it("tolerates an empty field list without raising a property error", function()
    local r = parser.parse("findByName", {})
    t.eq(r.predicates[1].property, "name")
    t.eq(r.errors, {})
  end)

  t.it("attaches the resolved field to the predicate", function()
    local r = parser.parse("findByEmail", FIELDS)
    t.eq(r.predicates[1].field.java_type, "String")
    t.eq(r.predicates[1].field.annotations, { "Column(unique = true)" })
  end)
end)

t.describe("parser › terminal states", function()
  t.it("stays in subject as long as By hasn't been typed", function()
    t.eq(parser.parse("find", FIELDS).state, "subject")
    t.eq(parser.parse("findDistinct", FIELDS).state, "subject")
  end)

  t.it("waits for a property right after By", function()
    t.eq(parser.parse("findBy", FIELDS).state, "expect_property")
  end)

  t.it("waits for a property after a connector", function()
    t.eq(parser.parse("findByNameAnd", FIELDS).state, "expect_property")
    t.eq(parser.parse("findByNameOr", FIELDS).state, "expect_property")
  end)

  t.it("carries the still-being-typed connector as the last predicate's fragment", function()
    -- "findByNameAnd" is undecidable from the string alone: either an And
    -- not yet followed by a property, or a complete field named "nameAnd".
    -- Splitting NEVER consulting the field list (a plan constraint),
    -- split_on_keyword settles it the way PartTree does: And right at the
    -- end of a string, not followed by an uppercase letter, stays glued
    -- to the text. The "nameAnd" fragment therefore does land in
    -- predicates/params/errors; it's `state` — "expect_property" here —
    -- that tells the consumer not to trust it as-is. See the documented
    -- contract on M.parse.
    local r = parser.parse("findByNameAnd", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.predicates[1].property, "nameAnd")
    t.eq(r.errors, { { code = "unknown_property", message = "unknown property: nameAnd" } })
    t.eq(r.params, { { name = "nameAnd", java_type = "Object" } })
    t.eq(r.state, "expect_property")
  end)

  t.it("follows a property with no condition", function()
    t.eq(parser.parse("findByName", FIELDS).state, "after_property")
  end)

  t.it("follows an explicit condition", function()
    t.eq(parser.parse("findByNameContaining", FIELDS).state, "after_condition")
    t.eq(parser.parse("findByAgeBetween", FIELDS).state, "after_condition")
  end)

  t.it("waits for a sort property after OrderBy", function()
    t.eq(parser.parse("findByNameOrderBy", FIELDS).state, "order_property")
  end)

  t.it("carries the still-being-typed OrderBy as the last predicate's fragment", function()
    -- Same undecidability as And/Or above: "findByNameOrderBy" could be a
    -- complete field named "nameOrderBy". split_on_keyword rejects the
    -- split (OrderBy right at the end of the string, no uppercase letter
    -- follows), so "NameOrderBy" stays a whole part and becomes the
    -- SIMPLE_PROPERTY predicate "nameOrderBy", with its unknown_property
    -- error and associated parameter. `state` stays correct
    -- ("order_property") thanks to the sole fix kept in terminal_state.
    local r = parser.parse("findByNameOrderBy", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.predicates[1].property, "nameOrderBy")
    t.eq(r.order_by, {})
    t.eq(r.errors, { { code = "unknown_property", message = "unknown property: nameOrderBy" } })
    t.eq(r.params, { { name = "nameOrderBy", java_type = "Object" } })
    t.eq(r.state, "order_property")
  end)

  t.it("waits for a direction after a sort property", function()
    t.eq(parser.parse("findByNameOrderByAge", FIELDS).state, "order_direction")
    t.eq(parser.parse("findByNameOrderByAgeAsc", FIELDS).state, "order_direction")
  end)
end)

t.describe("parser › return_types", function()
  local function rts(source)
    return parser.return_types(parser.parse(source, FIELDS), "UserEntity")
  end

  t.it("offers void then long for a delete", function()
    t.eq(rts("deleteByName"), { "void", "long" })
    t.eq(rts("removeByName"), { "void", "long" })
  end)

  t.it("offers the deduced type then Stream for a stream", function()
    t.eq(rts("streamByName"), { "List<UserEntity>", "Stream<UserEntity>" })
  end)

  t.it("keeps the deduced type first even when it is Optional", function()
    -- A stream of at most one row is legitimate, and so is asking for
    -- that row directly: both are offered, neither is imposed.
    t.eq(rts("streamById"), { "Optional<UserEntity>", "Stream<UserEntity>" })
    t.eq(rts("streamTop5ByName"), { "List<UserEntity>", "Stream<UserEntity>" })
  end)

  t.it("never offers Stream to the five other query keywords", function()
    for _, source in ipairs({ "findByName", "readByName", "getByName", "queryByName", "searchByName" }) do
      t.eq(rts(source), { "List<UserEntity>" })
    end
  end)

  t.it("never offers Stream to count or exists", function()
    t.eq(rts("countByName"), { "long" })
    t.eq(rts("existsByName"), { "boolean" })
  end)

  t.it("offers a single type when nothing is open to choice", function()
    t.eq(rts("findByName"), { "List<UserEntity>" })
    t.eq(rts("findById"), { "Optional<UserEntity>" })
  end)
end)

t.describe("parser › return_type", function()
  local function rt(source)
    return parser.return_type(parser.parse(source, FIELDS), "UserEntity")
  end

  t.it("answers the first candidate", function()
    t.eq(rt("streamByName"), "List<UserEntity>")
    t.eq(rt("deleteByName"), "void")
  end)

  t.it("gives long for count", function()
    t.eq(rt("countByName"), "long")
  end)

  t.it("gives boolean for exists", function()
    t.eq(rt("existsByName"), "boolean")
  end)

  t.it("leads with void for delete", function()
    t.eq(rt("deleteByName"), "void")
    t.eq(rt("removeByName"), "void")
  end)

  t.it("leads with List for stream", function()
    -- `stream` is one of the six general query keywords, strictly
    -- equivalent to `find` in PartTree: nothing in Spring makes it return
    -- a Stream on its own, so the deduced type stays first.
    t.eq(rt("streamByName"), "List<UserEntity>")
  end)

  t.it("gives Optional for First and Top without a number", function()
    t.eq(rt("findFirstByName"), "Optional<UserEntity>")
    t.eq(rt("findTopByName"), "Optional<UserEntity>")
  end)

  t.it("gives Optional for the explicit Top1 form", function()
    t.eq(rt("findTop1ByName"), "Optional<UserEntity>")
  end)

  t.it("gives List for a limit greater than one", function()
    t.eq(rt("findTop5ByName"), "List<UserEntity>")
  end)

  t.it("gives Optional for an equality on an Id-annotated field", function()
    t.eq(rt("findById"), "Optional<UserEntity>")
  end)

  t.it("gives Optional for an equality on a unique field", function()
    t.eq(rt("findByEmail"), "Optional<UserEntity>")
  end)

  t.it("gives List for a non-unique field", function()
    t.eq(rt("findByName"), "List<UserEntity>")
  end)

  t.it("gives List for a non-equality condition on a unique field", function()
    t.eq(rt("findByIdGreaterThan"), "List<UserEntity>")
  end)

  t.it("gives List as soon as a second predicate joins a unique field", function()
    t.eq(rt("findByEmailAndName"), "List<UserEntity>")
  end)

  t.it("gives List when an Or joins the predicates", function()
    t.eq(rt("findByEmailOrName"), "List<UserEntity>")
  end)
end)

local function labels_of(suggestions)
  local out = {}
  for _, s in ipairs(suggestions) do
    out[#out + 1] = s.label
  end
  return out
end

local function contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

t.describe("parser › suggestions", function()
  local function suggest(source)
    return parser.suggestions(parser.parse(source, FIELDS), FIELDS)
  end

  t.it("offers the fields right after By", function()
    local labels = labels_of(suggest("findBy"))
    for _, name in ipairs({ "id", "name", "email", "age", "createdAt", "active", "orders" }) do
      t.truthy(contains(labels, name), "missing field: " .. name)
    end
  end)

  t.it("offers text conditions on a String field", function()
    local labels = labels_of(suggest("findByName"))
    for _, keyword in ipairs({ "Containing", "StartingWith", "EndingWith", "Like", "IsNull" }) do
      t.truthy(contains(labels, keyword), "missing keyword: " .. keyword)
    end
  end)

  t.it("does not offer text conditions on a numeric field", function()
    local labels = labels_of(suggest("findByAge"))
    t.eq(contains(labels, "Containing"), false)
    t.eq(contains(labels, "StartingWith"), false)
    t.truthy(contains(labels, "Between"), "Between should be offered on a numeric field")
    t.truthy(contains(labels, "GreaterThan"), "GreaterThan should be offered")
  end)

  t.it("does not offer Between on a String field", function()
    local labels = labels_of(suggest("findByName"))
    t.eq(contains(labels, "Between"), false)
    t.eq(contains(labels, "After"), false)
  end)

  t.it("offers After and Before on a temporal field", function()
    local labels = labels_of(suggest("findByCreatedAt"))
    t.truthy(contains(labels, "After"), "After should be offered")
    t.truthy(contains(labels, "Before"), "Before should be offered")
    t.eq(contains(labels, "Containing"), false)
  end)

  t.it("offers True and False on a boolean, but not IsNull on a primitive", function()
    local labels = labels_of(suggest("findByActive"))
    t.truthy(contains(labels, "True"), "True should be offered")
    t.truthy(contains(labels, "False"), "False should be offered")
    t.eq(contains(labels, "IsNull"), false)
  end)

  t.it("offers IsEmpty only on a collection", function()
    t.truthy(contains(labels_of(suggest("findByOrders")), "IsEmpty"), "IsEmpty expected")
    t.eq(contains(labels_of(suggest("findByName")), "IsEmpty"), false)
  end)

  t.it("never offers keywords unsupported by JPA", function()
    for _, source in ipairs({ "findByName", "findByAge", "findByCreatedAt", "findByOrders" }) do
      local labels = labels_of(suggest(source))
      for _, forbidden in ipairs({ "Regex", "Matches", "MatchesRegex", "Exists", "Near", "Within" }) do
        t.eq(contains(labels, forbidden), false)
      end
    end
  end)

  t.it("offers connectors and OrderBy after a property", function()
    local labels = labels_of(suggest("findByName"))
    t.truthy(contains(labels, "And"), "And expected")
    t.truthy(contains(labels, "Or"), "Or expected")
    t.truthy(contains(labels, "OrderBy"), "OrderBy expected")
  end)

  t.it("offers IgnoreCase after a text condition", function()
    local labels = labels_of(suggest("findByNameContaining"))
    t.truthy(contains(labels, "IgnoreCase"), "IgnoreCase expected")
  end)

  t.it("does not offer IgnoreCase after a numeric condition", function()
    local labels = labels_of(suggest("findByAgeBetween"))
    t.eq(contains(labels, "IgnoreCase"), false)
  end)

  t.it("offers directions after a sort property", function()
    local labels = labels_of(suggest("findByNameOrderByAge"))
    t.truthy(contains(labels, "Asc"), "Asc expected")
    t.truthy(contains(labels, "Desc"), "Desc expected")
  end)

  t.it("offers fields after OrderBy", function()
    local labels = labels_of(suggest("findByNameOrderBy"))
    t.truthy(contains(labels, "age"), "field expected after OrderBy")
  end)

  t.it("offers modifiers in the subject", function()
    local labels = labels_of(suggest("find"))
    t.truthy(contains(labels, "Distinct"), "Distinct expected")
    t.truthy(contains(labels, "First"), "First expected")
    t.truthy(contains(labels, "Top"), "Top expected")
    t.truthy(contains(labels, "By"), "By expected")
  end)

  t.it("offers every introducer on an empty string", function()
    local labels = labels_of(suggest(""))
    for _, keyword in ipairs({ "find", "count", "exists", "delete" }) do
      t.truthy(contains(labels, keyword), "missing introducer: " .. keyword)
    end
  end)

  t.it("restricts introducers to the ones the fragment starts", function()
    -- Before fragment-based completion, all ten introducers were offered
    -- regardless of the typed text; "fin" only starts one of them.
    local labels = labels_of(suggest("fin"))
    t.truthy(contains(labels, "find"), "find expected")
    for _, keyword in ipairs({ "count", "exists", "delete", "By", "Distinct" }) do
      t.eq(contains(labels, keyword), false)
    end
  end)

  t.it("no longer offers introducers once one is recognised", function()
    local labels = labels_of(suggest("find"))
    t.eq(contains(labels, "find"), false)
    t.truthy(contains(labels, "Distinct"), "Distinct expected")
    t.truthy(contains(labels, "First"), "First expected")
    t.truthy(contains(labels, "Top"), "Top expected")
    t.truthy(contains(labels, "By"), "By expected")
  end)

  t.it("does not offer First and Top after count", function()
    local labels = labels_of(suggest("count"))
    t.eq(contains(labels, "First"), false)
    t.eq(contains(labels, "Top"), false)
    t.truthy(contains(labels, "Distinct"), "Distinct is still offered")
  end)

  t.it("narrows suggestions to the neutral set on an unknown type", function()
    local fields = { { name = "status", java_type = "Status", annotations = {} } }
    local labels = labels_of(parser.suggestions(parser.parse("findByStatus", fields), fields))
    for _, keyword in ipairs({ "Is", "Equals", "Not", "IsNull", "IsNotNull", "In", "NotIn" }) do
      t.truthy(contains(labels, keyword), "incomplete neutral set: " .. keyword)
    end
    for _, keyword in ipairs({ "Containing", "Between", "True", "IsEmpty" }) do
      t.eq(contains(labels, keyword), false)
    end
  end)
end)

-- Completing a partial token: the plugin's very own scenario. As long as
-- the end of the string doesn't resolve, suggestions must REPLACE this
-- fragment rather than append to it — without which typing one more
-- character made every useful suggestion disappear, or produced
-- absurdities like "findDistDistinct".
t.describe("parser › suggestions on a fragment", function()
  local function suggest(source, fields)
    fields = fields or FIELDS
    return parser.suggestions(parser.parse(source, fields), fields)
  end

  -- Text actually inserted: the label replaces `replace_length`
  -- characters at the end of the source. Reproduces what source.lua
  -- does, so expectations can be stated in their observable form.
  local function inserted(source, label, fields)
    for _, s in ipairs(suggest(source, fields)) do
      if s.label == label then
        local text = s.label
        if s.kind == "property" then
          text = text:sub(1, 1):upper() .. text:sub(2)
        end
        return source:sub(1, #source - s.replace_length) .. text
      end
    end
    return nil
  end

  t.it("completes a condition keyword already started", function()
    t.eq(inserted("findByNameCont", "Containing"), "findByNameContaining")
    t.eq(inserted("findByNameCont", "Contains"), "findByNameContains")
  end)

  t.it("only offers what the fragment starts", function()
    local labels = labels_of(suggest("findByNameCont"))
    t.eq(labels, { "Containing", "Contains" })
  end)

  t.it("completes a field name already started", function()
    t.eq(inserted("findByNa", "name"), "findByName")
    t.eq(labels_of(suggest("findByNa")), { "name" })
  end)

  t.it("completes a field whose name ends in a connector", function()
    t.eq(inserted("findByLogicalAn", "logicalAnd"), "findByLogicalAnd")
  end)

  t.it("completes a connector already started after a property", function()
    t.eq(inserted("findByNameAn", "And"), "findByNameAnd")
    t.eq(inserted("findByNameOrderB", "OrderBy"), "findByNameOrderBy")
  end)

  t.it("completes a subject modifier without duplicating it", function()
    t.eq(inserted("findDist", "Distinct"), "findDistinct")
    t.eq(inserted("findDistinctFir", "First"), "findDistinctFirst")
    t.eq(inserted("findTop5B", "By"), "findTop5By")
  end)

  t.it("does not re-offer a modifier already in place", function()
    t.eq(contains(labels_of(suggest("findDistinct")), "Distinct"), false)
    t.eq(contains(labels_of(suggest("findFirst")), "First"), false)
    t.truthy(contains(labels_of(suggest("findDistinct")), "By"), "By is still offered")
  end)

  t.it("offers nothing on a fragment matching nothing", function()
    t.eq(suggest("findByZzz"), {})
    t.eq(suggest("findByNameZzz"), {})
  end)

  t.it("treats a fragment equal to a complete field name as resolved", function()
    local r = parser.parse("findByName", FIELDS)
    t.eq(r.fragment, "")
    for _, s in ipairs(parser.suggestions(r, FIELDS)) do
      t.eq(s.replace_length, 0)
    end
    t.eq(inserted("findByName", "Containing"), "findByNameContaining")
    t.eq(inserted("findByName", "And"), "findByNameAnd")
  end)

  t.it("completes a sort property already started", function()
    t.eq(inserted("findByNameOrderByNa", "name"), "findByNameOrderByName")
    t.eq(labels_of(suggest("findByNameOrderByNa")), { "name" })
  end)

  t.it("completes a sort direction already started", function()
    t.eq(inserted("findByNameOrderByAgeA", "Asc"), "findByNameOrderByAgeAsc")
    t.eq(inserted("findByNameOrderByAgeDe", "Desc"), "findByNameOrderByAgeDesc")
  end)

  t.it("does not offer a second direction on a closed sort block", function()
    t.eq(contains(labels_of(suggest("findByNameOrderByAgeAsc")), "Asc"), false)
    t.truthy(contains(labels_of(suggest("findByNameOrderByAgeAsc")), "name"), "field expected")
  end)

  t.it("guesses no fragment without a field list", function()
    -- Without fields, validation is disabled (§6): nothing distinguishes a
    -- fragment from a completed property. We then fall back to the old
    -- behaviour — appending — rather than guessing.
    local r = parser.parse("findByNameCont", {})
    t.eq(r.fragment, "")
    local labels = labels_of(parser.suggestions(r, {}))
    t.eq(labels, { "And", "Or", "OrderBy" })
  end)
end)
