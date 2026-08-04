local t = require("harness")
local grammar = require("springdata.grammar")

t.describe("grammar › introducteurs", function()
  t.it("couvre exactement les dix mots-clés de PartTree", function()
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

  t.it("n'a aucun introducteur préfixe d'un autre", function()
    for _, a in ipairs(grammar.introducers) do
      for _, b in ipairs(grammar.introducers) do
        if a.keyword ~= b.keyword then
          t.truthy(
            b.keyword:sub(1, #a.keyword) ~= a.keyword,
            a.keyword .. " est préfixe de " .. b.keyword
          )
        end
      end
    end
  end)
end)

t.describe("grammar › modificateurs", function()
  t.it("expose Distinct, First/Top, les directions et les connecteurs", function()
    t.eq(grammar.distinct, "Distinct")
    t.eq(grammar.limiting, { "First", "Top" })
    t.eq(grammar.directions, { "Asc", "Desc" })
    t.eq(grammar.order_by, "OrderBy")
    t.eq(grammar.connectors, { "And", "Or" })
  end)

  t.it("liste les variantes IgnoreCase de la plus longue à la plus courte", function()
    t.eq(grammar.ignore_case, { "IgnoringCase", "IgnoreCase" })
    t.eq(grammar.all_ignore_case, { "AllIgnoringCase", "AllIgnoreCase" })
  end)
end)

t.describe("grammar › boxing", function()
  t.it("associe chaque primitif à son wrapper", function()
    t.eq(grammar.boxed["int"], "Integer")
    t.eq(grammar.boxed["long"], "Long")
    t.eq(grammar.boxed["char"], "Character")
    t.eq(grammar.boxed["boolean"], "Boolean")
    t.eq(grammar.boxed["double"], "Double")
  end)
end)

t.describe("grammar › types de conditions", function()
  t.it("reproduit exactement l'ordre de Part.Type.ALL", function()
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

  t.it("transcrit le nombre d'arguments de Part.Type", function()
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

  t.it("marque comme non-JPA les quatre types hors périmètre", function()
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

  t.it("n'a aucun alias dupliqué entre types", function()
    local owner = {}
    for _, ty in ipairs(grammar.types) do
      for _, kw in ipairs(ty.keywords) do
        t.truthy(
          owner[kw] == nil,
          "alias « " .. kw .. " » présent sur " .. tostring(owner[kw]) .. " et " .. ty.name
        )
        owner[kw] = ty.name
      end
    end
  end)

  t.it("déclare tous les alias documentés pour les types à variantes", function()
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

  t.it("marque IS_NULL et IS_NOT_NULL comme exigeant un type nullable", function()
    local by_name = {}
    for _, ty in ipairs(grammar.types) do
      by_name[ty.name] = ty
    end
    t.eq(by_name["IS_NULL"].requires_nullable, true)
    t.eq(by_name["IS_NOT_NULL"].requires_nullable, true)
    t.eq(by_name["SIMPLE_PROPERTY"].requires_nullable, nil)
  end)
end)

t.describe("grammar › catégories de types Java", function()
  t.it("classe les types textuels", function()
    t.eq(grammar.categories["String"], "string")
    t.eq(grammar.categories["char"], "string")
    t.eq(grammar.categories["Character"], "string")
  end)

  t.it("classe les types numériques, primitifs et wrappers", function()
    for _, name in ipairs({
      "int", "long", "short", "byte", "float", "double",
      "Integer", "Long", "Short", "Byte", "Float", "Double",
      "BigDecimal", "BigInteger",
    }) do
      t.eq(grammar.categories[name], "numeric")
    end
  end)

  t.it("classe les types temporels", function()
    for _, name in ipairs({
      "LocalDate", "LocalTime", "LocalDateTime", "Instant",
      "ZonedDateTime", "OffsetDateTime", "Date", "Timestamp",
      "Year", "YearMonth",
    }) do
      t.eq(grammar.categories[name], "temporal")
    end
  end)

  t.it("classe les booléens", function()
    t.eq(grammar.categories["boolean"], "boolean")
    t.eq(grammar.categories["Boolean"], "boolean")
  end)

  t.it("ne classe pas les types inconnus", function()
    t.eq(grammar.categories["UserEntity"], nil)
    t.eq(grammar.categories["Status"], nil)
  end)

  t.it("liste les conteneurs et les primitifs", function()
    t.eq(grammar.collection_types, { "List", "Set", "Collection" })
    t.eq(grammar.primitives["int"], true)
    t.eq(grammar.primitives["boolean"], true)
    t.eq(grammar.primitives["Integer"], nil)
    t.eq(grammar.primitives["String"], nil)
  end)
end)
