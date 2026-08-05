local t = require("harness")
local grammar = require("spring-data.grammar")

t.describe("grammar › introducers", function()
  t.it("covers exactly PartTree's ten keywords", function()
    local seen = {}
    for _, intro in ipairs(grammar.introducers) do
      seen[intro.keyword] = intro.category
    end
    t.eq(seen, {
      find = "query",
      read = "query",
      get = "query",
      query = "query",
      search = "query",
      stream = "query",
      count = "count",
      exists = "exists",
      delete = "delete",
      remove = "delete",
    })
  end)

  t.it("has no introducer that's a prefix of another", function()
    for _, a in ipairs(grammar.introducers) do
      for _, b in ipairs(grammar.introducers) do
        if a.keyword ~= b.keyword then
          t.truthy(
            b.keyword:sub(1, #a.keyword) ~= a.keyword,
            a.keyword .. " is a prefix of " .. b.keyword
          )
        end
      end
    end
  end)
end)

t.describe("grammar › modifiers", function()
  t.it("exposes Distinct, First/Top, directions and connectors", function()
    t.eq(grammar.distinct, "Distinct")
    t.eq(grammar.limiting, { "First", "Top" })
    t.eq(grammar.directions, { "Asc", "Desc" })
    t.eq(grammar.order_by, "OrderBy")
    t.eq(grammar.connectors, { "And", "Or" })
  end)

  t.it("lists IgnoreCase variants from longest to shortest", function()
    t.eq(grammar.ignore_case, { "IgnoringCase", "IgnoreCase" })
    t.eq(grammar.all_ignore_case, { "AllIgnoringCase", "AllIgnoreCase" })
  end)
end)

t.describe("grammar › boxing", function()
  t.it("maps each primitive to its wrapper", function()
    t.eq(grammar.boxed["int"], "Integer")
    t.eq(grammar.boxed["long"], "Long")
    t.eq(grammar.boxed["char"], "Character")
    t.eq(grammar.boxed["boolean"], "Boolean")
    t.eq(grammar.boxed["double"], "Double")
  end)
end)

t.describe("grammar › condition types", function()
  t.it("reproduces Part.Type.ALL's exact order", function()
    local names = {}
    for _, ty in ipairs(grammar.types) do
      names[#names + 1] = ty.name
    end
    t.eq(names, {
      "IS_NOT_NULL",
      "IS_NULL",
      "BETWEEN",
      "LESS_THAN",
      "LESS_THAN_EQUAL",
      "GREATER_THAN",
      "GREATER_THAN_EQUAL",
      "BEFORE",
      "AFTER",
      "NOT_LIKE",
      "LIKE",
      "STARTING_WITH",
      "ENDING_WITH",
      "IS_NOT_EMPTY",
      "IS_EMPTY",
      "NOT_CONTAINING",
      "CONTAINING",
      "NOT_IN",
      "IN",
      "NEAR",
      "WITHIN",
      "REGEX",
      "EXISTS",
      "TRUE",
      "FALSE",
      "NEGATING_SIMPLE_PROPERTY",
      "SIMPLE_PROPERTY",
    })
  end)

  t.it("transcribes Part.Type's argument counts", function()
    local args = {}
    for _, ty in ipairs(grammar.types) do
      args[ty.name] = ty.args
    end
    t.eq(args["BETWEEN"], 2)
    for _, name in ipairs({
      "IS_NULL", "IS_NOT_NULL", "IS_EMPTY", "IS_NOT_EMPTY",
      "TRUE", "FALSE", "EXISTS",
    }) do
      t.eq(args[name], 0)
    end
    for _, name in ipairs({
      "LESS_THAN", "GREATER_THAN_EQUAL", "LIKE", "CONTAINING",
      "IN", "SIMPLE_PROPERTY", "NEGATING_SIMPLE_PROPERTY",
    }) do
      t.eq(args[name], 1)
    end
  end)

  t.it("marks the four out-of-scope types as non-JPA", function()
    local jpa = {}
    for _, ty in ipairs(grammar.types) do
      jpa[ty.name] = ty.jpa
    end
    t.eq(jpa["REGEX"], false)
    t.eq(jpa["EXISTS"], false)
    t.eq(jpa["NEAR"], false)
    t.eq(jpa["WITHIN"], false)
    t.eq(jpa["CONTAINING"], true)
    t.eq(jpa["IS_EMPTY"], true)
  end)

  t.it("has no alias duplicated across types", function()
    local owner = {}
    for _, ty in ipairs(grammar.types) do
      for _, kw in ipairs(ty.keywords) do
        t.truthy(
          owner[kw] == nil,
          "alias \"" .. kw .. "\" present on " .. tostring(owner[kw]) .. " and " .. ty.name
        )
        owner[kw] = ty.name
      end
    end
  end)

  t.it("declares every documented alias for multi-variant types", function()
    local by_name = {}
    for _, ty in ipairs(grammar.types) do
      by_name[ty.name] = ty
    end
    t.eq(by_name["STARTING_WITH"].keywords, { "IsStartingWith", "StartingWith", "StartsWith" })
    t.eq(by_name["CONTAINING"].keywords, { "IsContaining", "Containing", "Contains" })
    t.eq(by_name["REGEX"].keywords, { "MatchesRegex", "Matches", "Regex" })
    t.eq(by_name["SIMPLE_PROPERTY"].keywords, { "Is", "Equals" })
    t.eq(by_name["IS_NOT_NULL"].keywords, { "IsNotNull", "NotNull" })
  end)

  t.it("marks IS_NULL and IS_NOT_NULL as requiring a nullable type", function()
    local by_name = {}
    for _, ty in ipairs(grammar.types) do
      by_name[ty.name] = ty
    end
    t.eq(by_name["IS_NULL"].requires_nullable, true)
    t.eq(by_name["IS_NOT_NULL"].requires_nullable, true)
    t.eq(by_name["SIMPLE_PROPERTY"].requires_nullable, nil)
  end)
end)

t.describe("grammar › Java type categories", function()
  t.it("classifies text types", function()
    t.eq(grammar.categories["String"], "string")
    t.eq(grammar.categories["char"], "string")
    t.eq(grammar.categories["Character"], "string")
  end)

  t.it("classifies numeric types, primitives and wrappers", function()
    for _, name in ipairs({
      "int", "long", "short", "byte", "float", "double",
      "Integer", "Long", "Short", "Byte", "Float", "Double",
      "BigDecimal", "BigInteger",
    }) do
      t.eq(grammar.categories[name], "numeric")
    end
  end)

  t.it("classifies temporal types", function()
    for _, name in ipairs({
      "LocalDate", "LocalTime", "LocalDateTime", "Instant",
      "ZonedDateTime", "OffsetDateTime", "Date", "Timestamp",
      "Year", "YearMonth",
    }) do
      t.eq(grammar.categories[name], "temporal")
    end
  end)

  t.it("classifies booleans", function()
    t.eq(grammar.categories["boolean"], "boolean")
    t.eq(grammar.categories["Boolean"], "boolean")
  end)

  t.it("does not classify unknown types", function()
    t.eq(grammar.categories["UserEntity"], nil)
    t.eq(grammar.categories["Status"], nil)
  end)

  t.it("lists containers and primitives", function()
    t.eq(grammar.collection_types, { "List", "Set", "Collection" })
    t.eq(grammar.primitives["int"], true)
    t.eq(grammar.primitives["boolean"], true)
    t.eq(grammar.primitives["Integer"], nil)
    t.eq(grammar.primitives["String"], nil)
  end)
end)
