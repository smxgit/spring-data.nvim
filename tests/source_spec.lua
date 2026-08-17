-- Coverage of source.lua's pure functions.
--
-- This module is loadable under a bare interpreter: its references to
-- `vim` all live inside the bodies of `enabled` and `get_completions`,
-- never at load time. The suite therefore stays runnable via
-- `luajit tests/run.lua`, without Neovim. What this file doesn't cover —
-- `get_completions` end to end, which needs treesitter and jdtls — is
-- checked by hand under `nvim --headless`; see the fix-pass report.
local t = require("harness")
local parser = require("spring-data.parser")
local source = require("spring-data.source")
local spring_data = require("spring-data")

local internal = source.internal

local FIELDS = {
  { name = "id", java_type = "Long", annotations = { "Id" } },
  { name = "name", java_type = "String", annotations = {} },
  { name = "age", java_type = "int", annotations = {} },
}

t.describe("source › current_prefix", function()
  t.it("keeps the identifier to the left of the cursor", function()
    t.eq(internal.current_prefix({ line = "  List<User> findByName", cursor = { 1, 23 } }), "findByName")
  end)

  t.it("stops at anything that can't be part of a method name", function()
    t.eq(internal.current_prefix({ line = "  UserEntity findBy", cursor = { 1, 19 } }), "findBy")
    t.eq(internal.current_prefix({ line = "  findByName(String n)", cursor = { 1, 12 } }), "findByName")
  end)

  t.it("ignores what follows the cursor", function()
    t.eq(internal.current_prefix({ line = "  findByNameAndAge", cursor = { 1, 12 } }), "findByName")
  end)

  t.it("returns an empty string when there's no identifier", function()
    t.eq(internal.current_prefix({ line = "  ", cursor = { 1, 2 } }), "")
    t.eq(internal.current_prefix({}), "")
  end)
end)

t.describe("source › capitalize", function()
  t.it("uppercases the first letter", function()
    t.eq(internal.capitalize("name"), "Name")
    t.eq(internal.capitalize("createdAt"), "CreatedAt")
  end)

  t.it("leaves an empty string unchanged", function()
    t.eq(internal.capitalize(""), "")
  end)
end)

t.describe("source › fragment_text", function()
  t.it("appends when there's nothing to replace", function()
    local suggestion = { label = "Containing", kind = "keyword", replace_length = 0 }
    t.eq(internal.fragment_text("findByName", suggestion), "findByNameContaining")
  end)

  t.it("replaces the token being typed", function()
    local suggestion = { label = "Containing", kind = "keyword", replace_length = 4 }
    t.eq(internal.fragment_text("findByNameCont", suggestion), "findByNameContaining")
  end)

  t.it("capitalises a field name", function()
    local suggestion = { label = "name", kind = "property", replace_length = 2 }
    t.eq(internal.fragment_text("findByNa", suggestion), "findByName")
  end)

  t.it("replaces the entire typed text when the fragment equals it", function()
    local suggestion = { label = "find", kind = "modifier", replace_length = 3 }
    t.eq(internal.fragment_text("fin", suggestion), "find")
  end)

  t.it("tolerates a suggestion without replace_length", function()
    t.eq(internal.fragment_text("findByName", { label = "And", kind = "connector" }), "findByNameAnd")
  end)
end)

-- The text actually inserted, end to end: parse, suggestions, then the
-- composition the source performs. It's this whole path — not each half
-- taken in isolation — that the final review found broken.
t.describe("source › inserted text", function()
  local function inserted(prefix, label)
    local result = parser.parse(prefix, FIELDS)
    for _, suggestion in ipairs(parser.suggestions(result, FIELDS)) do
      if suggestion.label == label then
        return internal.fragment_text(prefix, suggestion)
      end
    end
    return nil
  end

  t.it("completes a keyword already started", function()
    t.eq(inserted("findByNameCont", "Containing"), "findByNameContaining")
    t.eq(inserted("findByNameCont", "Contains"), "findByNameContains")
  end)

  t.it("completes a field already started", function()
    t.eq(inserted("findByNa", "name"), "findByName")
  end)

  t.it("does not duplicate the subject modifier", function()
    t.eq(inserted("findDist", "Distinct"), "findDistinct")
  end)

  t.it("appends after a resolved property", function()
    t.eq(inserted("findByName", "Containing"), "findByNameContaining")
    t.eq(inserted("findByName", "And"), "findByNameAnd")
    t.eq(inserted("findBy", "age"), "findByAge")
  end)

  t.it("replaces the typed text as long as no introducer is recognised", function()
    t.eq(inserted("fin", "find"), "find")
  end)
end)

t.describe("source › build_snippet", function()
  t.it("places one tabstop per parameter", function()
    t.eq(
      internal.build_snippet("findByNameAndAge", "List<UserEntity>", {
        { name = "name", java_type = "String" },
        { name = "age", java_type = "int" },
      }),
      "List<UserEntity> findByNameAndAge(String ${1:name}, int ${2:age});$0"
    )
  end)

  t.it("produces an empty parameter list when the condition takes none", function()
    t.eq(
      internal.build_snippet("findByNameIsNull", "List<UserEntity>", {}),
      "List<UserEntity> findByNameIsNull();$0"
    )
  end)
end)

t.describe("source › offers_signature", function()
  local function offered(prefix, fields, fields_ok)
    return internal.offers_signature(parser.parse(prefix, fields), fields_ok)
  end

  t.it("offers the signature of a complete, validated method", function()
    t.eq(offered("findByName", FIELDS, true), true)
    t.eq(offered("findByNameContaining", FIELDS, true), true)
    t.eq(offered("findByNameOrderByAge", FIELDS, true), true)
  end)

  t.it("never offers a bare findBy", function()
    t.eq(offered("findBy", FIELDS, true), false)
    t.eq(offered("find", FIELDS, true), false)
    t.eq(offered("findByNameAnd", FIELDS, true), false)
  end)

  t.it("stays silent on a method Spring would reject", function()
    t.eq(offered("findByAgeContaining", FIELDS, true), false)
    t.eq(offered("findByAgeIgnoreCase", FIELDS, true), false)
    t.eq(offered("findByNameOrderByAsc", FIELDS, true), false)
  end)

  -- Without fields, `errors` is empty because nothing was checked: the
  -- source used to offer "findByNameCont(Object nameCont)" while jdtls
  -- hadn't responded yet.
  t.it("stays silent when validation could not take place", function()
    t.eq(offered("findByName", {}, false), false)
    t.eq(offered("findByNameCont", {}, false), false)
  end)

  t.it("distinguishes a field-less entity from an unavailable list", function()
    t.eq(offered("findByName", {}, true), true)
  end)
end)

-- One signature item per candidate return type. The choice belongs to the
-- call site, not to the project: the same repository legitimately wants a
-- Stream in one method and a List in the next.
t.describe("source › signature items", function()
  local function items_for(source)
    local result = parser.parse(source, FIELDS)
    return internal.signature_items(source, result, "UserEntity")
  end

  t.it("emits one item per candidate", function()
    local items = items_for("streamByName")
    t.eq(#items, 2)
    t.eq(items[1].labelDetails.description, "List<UserEntity>")
    t.eq(items[2].labelDetails.description, "Stream<UserEntity>")
  end)

  t.it("gives every candidate the same label, so both survive filtering", function()
    local items = items_for("streamByName")
    t.eq(items[1].label, "streamByName")
    t.eq(items[2].label, "streamByName")
    t.eq(items[1].filterText, items[2].filterText)
  end)

  t.it("carries the candidate's own type into its snippet", function()
    local items = items_for("streamByName")
    t.eq(items[1].insertText, "List<UserEntity> streamByName(String ${1:name});$0")
    t.eq(items[2].insertText, "Stream<UserEntity> streamByName(String ${1:name});$0")
  end)

  t.it("keeps the candidates in order, ahead of the fragments", function()
    local items = items_for("streamByName")
    t.eq(items[1].sortText, "000streamByName")
    t.eq(items[2].sortText, "001streamByName")
    -- fragments sort under "01" (properties) and "02" (keywords)
    t.truthy(items[2].sortText < "01", "a signature must outrank every fragment")
  end)

  t.it("offers void and long for a delete", function()
    local items = items_for("deleteByName")
    t.eq(#items, 2)
    t.eq(items[1].labelDetails.description, "void")
    t.eq(items[2].labelDetails.description, "long")
  end)

  t.it("emits a single item where nothing is open to choice", function()
    t.eq(#items_for("findByName"), 1)
    t.eq(#items_for("countByName"), 1)
    t.eq(#items_for("existsByName"), 1)
  end)
end)
