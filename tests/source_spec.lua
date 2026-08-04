-- Couverture des fonctions pures de source.lua.
--
-- Ce module est chargeable sous un interpréteur nu : ses références à `vim`
-- vivent toutes dans le corps de `enabled` et `get_completions`, jamais au
-- chargement. La suite reste donc exécutable par `luajit tests/run.lua`,
-- sans Neovim. Ce que ce fichier ne couvre pas — `get_completions` de bout
-- en bout, qui a besoin de treesitter et de jdtls — est vérifié à la main
-- sous `nvim --headless` ; voir le rapport de la passe de correction.
local t = require("harness")
local parser = require("springdata.parser")
local source = require("springdata.source")
local springdata = require("springdata")

local internal = source.internal

local FIELDS = {
  { name = "id", java_type = "Long", annotations = { "Id" } },
  { name = "name", java_type = "String", annotations = {} },
  { name = "age", java_type = "int", annotations = {} },
}

t.describe("source › current_prefix", function()
  t.it("retient l'identifiant à gauche du curseur", function()
    t.eq(internal.current_prefix({ line = "  List<User> findByName", cursor = { 1, 23 } }), "findByName")
  end)

  t.it("s'arrête sur ce qui ne peut pas faire partie d'un nom de méthode", function()
    t.eq(internal.current_prefix({ line = "  UserEntity findBy", cursor = { 1, 19 } }), "findBy")
    t.eq(internal.current_prefix({ line = "  findByName(String n)", cursor = { 1, 12 } }), "findByName")
  end)

  t.it("ignore ce qui suit le curseur", function()
    t.eq(internal.current_prefix({ line = "  findByNameAndAge", cursor = { 1, 12 } }), "findByName")
  end)

  t.it("renvoie une chaîne vide en l'absence d'identifiant", function()
    t.eq(internal.current_prefix({ line = "  ", cursor = { 1, 2 } }), "")
    t.eq(internal.current_prefix({}), "")
  end)
end)

t.describe("source › capitalize", function()
  t.it("met la première lettre en majuscule", function()
    t.eq(internal.capitalize("name"), "Name")
    t.eq(internal.capitalize("createdAt"), "CreatedAt")
  end)

  t.it("laisse une chaîne vide intacte", function()
    t.eq(internal.capitalize(""), "")
  end)
end)

t.describe("source › fragment_text", function()
  t.it("ajoute à la suite quand rien n'est à remplacer", function()
    local suggestion = { label = "Containing", kind = "keyword", replace_length = 0 }
    t.eq(internal.fragment_text("findByName", suggestion), "findByNameContaining")
  end)

  t.it("remplace le jeton en cours de frappe", function()
    local suggestion = { label = "Containing", kind = "keyword", replace_length = 4 }
    t.eq(internal.fragment_text("findByNameCont", suggestion), "findByNameContaining")
  end)

  t.it("capitalise un nom de champ", function()
    local suggestion = { label = "name", kind = "property", replace_length = 2 }
    t.eq(internal.fragment_text("findByNa", suggestion), "findByName")
  end)

  t.it("remplace la totalité du texte tapé quand le fragment le vaut", function()
    local suggestion = { label = "find", kind = "modifier", replace_length = 3 }
    t.eq(internal.fragment_text("fin", suggestion), "find")
  end)

  t.it("tolère une suggestion sans replace_length", function()
    t.eq(internal.fragment_text("findByName", { label = "And", kind = "connector" }), "findByNameAnd")
  end)
end)

-- Le texte réellement inséré, bout en bout : parse, suggestions, puis la
-- composition faite par la source. C'est ce chemin complet — et non chaque
-- moitié prise isolément — que la relecture finale a trouvé cassé.
t.describe("source › texte inséré", function()
  local function inserted(prefix, label)
    local result = parser.parse(prefix, FIELDS)
    for _, suggestion in ipairs(parser.suggestions(result, FIELDS)) do
      if suggestion.label == label then
        return internal.fragment_text(prefix, suggestion)
      end
    end
    return nil
  end

  t.it("complète un mot-clé amorcé", function()
    t.eq(inserted("findByNameCont", "Containing"), "findByNameContaining")
    t.eq(inserted("findByNameCont", "Contains"), "findByNameContains")
  end)

  t.it("complète un champ amorcé", function()
    t.eq(inserted("findByNa", "name"), "findByName")
  end)

  t.it("ne duplique pas le modificateur de sujet", function()
    t.eq(inserted("findDist", "Distinct"), "findDistinct")
  end)

  t.it("ajoute à la suite d'une propriété résolue", function()
    t.eq(inserted("findByName", "Containing"), "findByNameContaining")
    t.eq(inserted("findByName", "And"), "findByNameAnd")
    t.eq(inserted("findBy", "age"), "findByAge")
  end)

  t.it("remplace le texte tapé tant qu'aucun introducteur n'est reconnu", function()
    t.eq(inserted("fin", "find"), "find")
  end)
end)

t.describe("source › build_snippet", function()
  t.it("place un tabstop par paramètre", function()
    t.eq(
      internal.build_snippet("findByNameAndAge", "List<UserEntity>", {
        { name = "name", java_type = "String" },
        { name = "age", java_type = "int" },
      }),
      "List<UserEntity> findByNameAndAge(String ${1:name}, int ${2:age});$0"
    )
  end)

  t.it("produit une liste de paramètres vide quand la condition n'en prend pas", function()
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

  t.it("propose la signature d'une méthode achevée et validée", function()
    t.eq(offered("findByName", FIELDS, true), true)
    t.eq(offered("findByNameContaining", FIELDS, true), true)
    t.eq(offered("findByNameOrderByAge", FIELDS, true), true)
  end)

  t.it("ne propose jamais de findBy nu", function()
    t.eq(offered("findBy", FIELDS, true), false)
    t.eq(offered("find", FIELDS, true), false)
    t.eq(offered("findByNameAnd", FIELDS, true), false)
  end)

  t.it("se tait sur une méthode que Spring rejetterait", function()
    t.eq(offered("findByAgeContaining", FIELDS, true), false)
    t.eq(offered("findByAgeIgnoreCase", FIELDS, true), false)
    t.eq(offered("findByNameOrderByAsc", FIELDS, true), false)
  end)

  -- Sans champs, `errors` est vide parce que rien n'a été vérifié : la
  -- source proposait « findByNameCont(Object nameCont) » tant que jdtls
  -- n'avait pas répondu.
  t.it("se tait quand la validation n'a pas pu avoir lieu", function()
    t.eq(offered("findByName", {}, false), false)
    t.eq(offered("findByNameCont", {}, false), false)
  end)

  t.it("distingue une entité sans champ d'une liste indisponible", function()
    t.eq(offered("findByName", {}, true), true)
  end)
end)

t.describe("source › options", function()
  local function with_setup_opts(opts, fn)
    local previous = springdata.opts
    springdata.opts = opts
    local ok, err = pcall(fn)
    springdata.opts = previous
    if not ok then
      error(err, 0)
    end
  end

  t.it("reprend les options de setup", function()
    with_setup_opts({ delete_return_type = "long" }, function()
      t.eq(internal.options({}).delete_return_type, "long")
      t.eq(internal.options(nil).delete_return_type, "long")
    end)
  end)

  t.it("laisse le provider avoir le dernier mot", function()
    with_setup_opts({ delete_return_type = "long" }, function()
      t.eq(internal.options({ delete_return_type = "void" }).delete_return_type, "void")
    end)
  end)

  -- Le défaut documenté ne servait à rien : il était écrit dans
  -- springdata.opts et lu par personne, `self.opts` venant du provider.
  t.it("achemine l'option jusqu'au type de retour", function()
    with_setup_opts({ delete_return_type = "long" }, function()
      local result = parser.parse("deleteByName", FIELDS)
      t.eq(parser.return_type(result, "UserEntity", internal.options({})), "long")
    end)
    with_setup_opts({ delete_return_type = "void" }, function()
      local result = parser.parse("deleteByName", FIELDS)
      t.eq(parser.return_type(result, "UserEntity", internal.options({})), "void")
    end)
  end)
end)
