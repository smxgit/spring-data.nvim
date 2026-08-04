local t = require("harness")
local grammar = require("springdata.grammar")

t.describe("grammar", function()
  t.it("expose la table des introducteurs", function()
    t.truthy(#grammar.introducers > 0, "introducers doit être non vide")
  end)
end)
