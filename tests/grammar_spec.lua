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
