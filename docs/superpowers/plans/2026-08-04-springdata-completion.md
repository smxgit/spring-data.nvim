# springdata.nvim — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fournir dans Neovim la complétion des *derived query methods* Spring Data JPA, de `findBy` jusqu'à l'insertion de la signature complète avec types de paramètres et type de retour corrects.

**Architecture:** Quatre modules en dépendance strictement descendante. `grammar.lua` ne contient que des tables de données, transcrites depuis le code source de Spring Data. `parser.lua` est du Lua pur, sans aucune référence à `vim`, donc testable par un interpréteur nu. `entity.lua` combine jdtls (localisation du fichier) et treesitter (extraction des champs et annotations). `source.lua` expose le tout comme provider `blink.cmp`.

**Tech Stack:** Lua 5.1 / LuaJIT, Neovim 0.12.4, nvim-jdtls, blink.cmp, LuaSnip, parser treesitter `java`.

## Global Constraints

- **Spec de référence** : `docs/superpowers/specs/2026-08-04-springdata-completion-design.md`. Toute divergence doit être signalée, pas absorbée silencieusement.
- **`grammar.lua` et `parser.lua` ne référencent jamais `vim`.** Ils doivent s'exécuter sous `luajit` nu. C'est ce qui rend la suite de tests possible sans Neovim.
- **`grammar.lua` ne contient aucune fonction**, uniquement des tables.
- **Le découpage de la chaîne ne consulte jamais la liste des champs.** Les champs servent à valider et à proposer, jamais à arbitrer un découpage. Fidélité stricte à `PartTree`.
- **L'ordre de `grammar.types` est significatif** et doit reproduire la constante `ALL` de `Part.java`. Le code Java porte le commentaire *« the order is important »*.
- **Neovim 0.12.4** : utiliser `vim.uv` (jamais `vim.loop`), `vim.lsp.codelens.enable`, `vim.lsp.semantic_tokens.enable`.
- **Langue** : commentaires et messages en français, identifiants en anglais.
- **Jamais de trailer `Co-Authored-By`** dans les commits.
- Chemin du dépôt : `~/Projects/springdata.nvim`. Toutes les commandes s'exécutent depuis cette racine.

## Structure des fichiers

| Fichier | Responsabilité |
|---|---|
| `lua/springdata/grammar.lua` | Tables de données pures : introducteurs, modificateurs, 27 types de conditions, catégories Java, boxing |
| `lua/springdata/parser.lua` | Analyse d'une chaîne partielle en Lua pur ; produit tokens, état terminal, paramètres, type de retour |
| `lua/springdata/entity.lua` | Résolution de `T` depuis `…Repository<T, ID>`, extraction des champs, cache |
| `lua/springdata/source.lua` | Provider blink.cmp : activation, génération des items, snippet LuaSnip |
| `lua/springdata/init.lua` | `setup(opts)`, options par défaut |
| `tests/harness.lua` | Mini framework : `describe`, `it`, `eq`, `report` |
| `tests/run.lua` | Point d'entrée `luajit tests/run.lua` |
| `tests/grammar_spec.lua` | Intégrité des tables |
| `tests/parser_spec.lua` | Cas limites du parser |

---

### Task 1: Runner de tests

**Files:**
- Create: `tests/harness.lua`
- Create: `tests/run.lua`
- Create: `lua/springdata/grammar.lua` (stub minimal, complété en Task 2)
- Create: `tests/grammar_spec.lua` (un seul test de fumée)

**Interfaces:**
- Produces: `harness.describe(name, fn)`, `harness.it(name, fn)`, `harness.eq(actual, expected)`, `harness.truthy(value, message)`, `harness.raises(fn, pattern)`, `harness.report() -> boolean`. Toutes les tâches suivantes consomment ces cinq fonctions.

- [ ] **Step 1: Écrire le harness**

Créer `tests/harness.lua` :

```lua
-- Mini framework de test. Aucune dépendance : doit tourner sous `luajit` nu.
local M = {}

local current_suite = nil
local stats = { passed = 0, failed = 0 }
local failures = {}

local function deep_equal(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

-- Rend une valeur lisible dans un message d'échec, clés triées pour un
-- affichage déterministe.
local function render(value, indent)
  indent = indent or ""
  if type(value) == "string" then
    return string.format("%q", value)
  end
  if type(value) ~= "table" then
    return tostring(value)
  end
  local keys = {}
  for k in pairs(value) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(x, y)
    return tostring(x) < tostring(y)
  end)
  if #keys == 0 then
    return "{}"
  end
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = indent .. "  " .. tostring(k) .. " = " .. render(value[k], indent .. "  ")
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

function M.describe(name, fn)
  current_suite = name
  fn()
  current_suite = nil
end

function M.it(name, fn)
  local label = (current_suite and (current_suite .. " › ") or "") .. name
  local ok, err = pcall(fn)
  if ok then
    stats.passed = stats.passed + 1
  else
    stats.failed = stats.failed + 1
    failures[#failures + 1] = { label = label, err = tostring(err) }
  end
end

function M.eq(actual, expected)
  if not deep_equal(actual, expected) then
    error("attendu :\n" .. render(expected) .. "\n\nobtenu :\n" .. render(actual), 2)
  end
end

function M.truthy(value, message)
  if not value then
    error(message or "valeur fausse ou nil", 2)
  end
end

function M.raises(fn, pattern)
  local ok, err = pcall(fn)
  if ok then
    error("aucune erreur levée, attendait : " .. tostring(pattern), 2)
  end
  if pattern and not tostring(err):find(pattern, 1, true) then
    error("erreur inattendue : " .. tostring(err) .. "\nattendait : " .. pattern, 2)
  end
end

function M.report()
  for _, f in ipairs(failures) do
    io.write("ÉCHEC  ", f.label, "\n", f.err, "\n\n")
  end
  io.write(string.format("%d réussis, %d échoués\n", stats.passed, stats.failed))
  return stats.failed == 0
end

return M
```

- [ ] **Step 2: Écrire le point d'entrée**

Créer `tests/run.lua` :

```lua
-- Point d'entrée de la suite : `luajit tests/run.lua` depuis la racine du dépôt.
local root = (arg and arg[0] or ""):match("^(.*)/tests/run%.lua$") or "."

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local harness = require("harness")

local specs = {
  "grammar_spec",
}

for _, spec in ipairs(specs) do
  require(spec)
end

os.exit(harness.report() and 0 or 1)
```

- [ ] **Step 3: Écrire le test de fumée**

Créer `tests/grammar_spec.lua` :

```lua
local t = require("harness")
local grammar = require("springdata.grammar")

t.describe("grammar", function()
  t.it("expose la table des introducteurs", function()
    t.truthy(#grammar.introducers > 0, "introducers doit être non vide")
  end)
end)
```

- [ ] **Step 4: Écrire le stub de grammar**

Créer `lua/springdata/grammar.lua` :

```lua
-- Données pures transcrites depuis les sources de Spring Data.
-- Ce module ne contient aucune fonction et ne référence jamais `vim`.
local M = {}

M.introducers = {
  { keyword = "find", category = "query" },
}

return M
```

- [ ] **Step 5: Lancer la suite**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: `1 réussis, 0 échoués`, code de sortie 0.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/springdata.nvim
git add tests/harness.lua tests/run.lua tests/grammar_spec.lua lua/springdata/grammar.lua
git commit -m "test: runner de tests minimal exécutable sous luajit nu"
```

---

### Task 2: `grammar.lua` — introducteurs, modificateurs, boxing

**Files:**
- Modify: `lua/springdata/grammar.lua`
- Modify: `tests/grammar_spec.lua`

**Interfaces:**
- Produces: `grammar.introducers` (liste de `{ keyword, category }`), `grammar.distinct` (chaîne `"Distinct"`), `grammar.limiting` (liste `{ "First", "Top" }`), `grammar.directions` (liste `{ "Asc", "Desc" }`), `grammar.order_by` (chaîne `"OrderBy"`), `grammar.connectors` (liste `{ "And", "Or" }`), `grammar.ignore_case` (liste `{ "IgnoringCase", "IgnoreCase" }`), `grammar.all_ignore_case` (liste `{ "AllIgnoringCase", "AllIgnoreCase" }`), `grammar.boxed` (table type primitif → wrapper).

- [ ] **Step 1: Écrire les tests**

Remplacer le contenu de `tests/grammar_spec.lua` par :

```lua
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
```

- [ ] **Step 2: Lancer pour constater l'échec**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: plusieurs ÉCHEC, dont `attendu : { ... } obtenu : { find = "query" }`.

- [ ] **Step 3: Implémenter**

Remplacer le contenu de `lua/springdata/grammar.lua` par :

```lua
-- Données pures transcrites depuis les sources de Spring Data.
-- Ce module ne contient aucune fonction et ne référence jamais `vim`.
--
-- Sources :
--   spring-data-commons : PartTree.java, Part.java, OrderBySource.java
--   spring-data-jpa     : JpaQueryCreator.java
local M = {}

-- PartTree : QUERY_PATTERN, COUNT_PATTERN, EXISTS_PATTERN, DELETE_PATTERN.
-- Aucun mot-clé n'est préfixe d'un autre, le premier match est donc sans ambiguïté.
M.introducers = {
  { keyword = "find", category = "query" },
  { keyword = "read", category = "query" },
  { keyword = "get", category = "query" },
  { keyword = "query", category = "query" },
  { keyword = "search", category = "query" },
  { keyword = "stream", category = "query" },
  { keyword = "count", category = "count" },
  { keyword = "exists", category = "exists" },
  { keyword = "delete", category = "delete" },
  { keyword = "remove", category = "delete" },
}

-- PartTree.Subject : DISTINCT, LIMITING_QUERY_PATTERN.
-- LIMITED_QUERY_TEMPLATE impose l'ordre Distinct puis First/Top, et ne
-- s'applique qu'à la catégorie « query ».
M.distinct = "Distinct"
M.limiting = { "First", "Top" }

-- PartTree.Predicate : ORDER_BY. OrderBySource : DIRECTION_KEYWORDS.
M.order_by = "OrderBy"
M.directions = { "Asc", "Desc" }

-- Découpage du prédicat : Or d'abord, And ensuite.
M.connectors = { "And", "Or" }

-- Part.IGNORE_CASE = "Ignor(ing|e)Case" et Predicate.ALL_IGNORE_CASE.
-- Ordonnés du plus long au plus court pour que la recherche littérale
-- ne tronque pas la variante longue.
M.ignore_case = { "IgnoringCase", "IgnoreCase" }
M.all_ignore_case = { "AllIgnoringCase", "AllIgnoreCase" }

-- Nécessaire pour typer les paramètres de In / NotIn : Collection<Integer>
-- et non Collection<int>, un générique Java n'acceptant pas de primitif.
M.boxed = {
  ["int"] = "Integer",
  ["long"] = "Long",
  ["short"] = "Short",
  ["byte"] = "Byte",
  ["float"] = "Float",
  ["double"] = "Double",
  ["char"] = "Character",
  ["boolean"] = "Boolean",
}

return M
```

- [ ] **Step 4: Lancer pour vérifier le succès**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: `5 réussis, 0 échoués`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/springdata.nvim
git add lua/springdata/grammar.lua tests/grammar_spec.lua
git commit -m "feat(grammar): introducteurs, modificateurs et table de boxing"
```

---

### Task 3: `grammar.lua` — les 27 types de conditions

**Files:**
- Modify: `lua/springdata/grammar.lua`
- Modify: `tests/grammar_spec.lua`

**Interfaces:**
- Produces: `grammar.types`, liste **ordonnée** de `{ name, keywords, args, jpa, accepts }`. `accepts` vaut soit la chaîne `"all"`, soit une liste de catégories. `grammar.types` porte aussi le champ booléen `requires_nullable` sur `IS_NULL` et `IS_NOT_NULL`.

**Contexte pour l'implémenteur.** L'ordre de cette liste reproduit la constante `ALL` de `Part.java`, que le code Java accompagne du commentaire *« Need to list them again explicitly as the order is important »*. Le parser retiendra le **premier** type dont un alias satisfait `endsWith` sur la part. C'est cet ordre qui garantit que `NotNull` donne `IS_NOT_NULL` et non `IS_NULL`, que `NotLike` donne `NOT_LIKE` et non `LIKE`. Ne pas réordonner, ne pas trier alphabétiquement.

Le champ `jpa` distingue « reconnu par le parser » de « proposé par la source ». `REGEX` et `EXISTS` figurent dans la table de la doc Spring, héritée de `spring-data-commons`, mais sont absents du `switch` de `JpaQueryCreator` : les utiliser lève `IllegalArgumentException: Unsupported keyword` au démarrage de l'application. `NEAR` et `WITHIN` sont supportés par JPA mais pour la recherche vectorielle, avec un paramètre `Score` ou `Range<Score>` — hors périmètre v1. Ces quatre types restent dans la table pour que le parser découpe correctement une chaîne les contenant, mais `jpa = false` les exclut des propositions.

- [ ] **Step 1: Écrire les tests**

Ajouter à la fin de `tests/grammar_spec.lua` :

```lua
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
```

- [ ] **Step 2: Lancer pour constater l'échec**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: 6 ÉCHEC, le premier signalant `attempt to get length of field 'types' (a nil value)` ou une comparaison contre `nil`.

- [ ] **Step 3: Implémenter**

Ajouter dans `lua/springdata/grammar.lua`, avant le `return M` :

```lua
-- Part.Type, transcrit dans l'ordre de la constante ALL.
--
-- L'ORDRE EST SIGNIFICATIF. Le code Java porte le commentaire « Need to list
-- them again explicitly as the order is important ». Le parser retient le
-- premier type dont un alias satisfait endsWith : c'est cet ordre qui fait
-- que « NotNull » donne IS_NOT_NULL et non IS_NULL, « NotLike » NOT_LIKE et
-- non LIKE, « NotIn » NOT_IN et non IN.
--
-- Champ `jpa` : false pour les types que le parser doit savoir reconnaître
-- mais que la source ne proposera jamais.
--   REGEX, EXISTS : absents du switch de JpaQueryCreator, lèvent
--                   « Unsupported keyword » au démarrage.
--   NEAR, WITHIN  : supportés par JPA, mais pour la recherche vectorielle,
--                   avec un paramètre Score ou Range<Score>. Hors v1.
--
-- Champ `accepts` : SEULE donnée qui ne provient pas de Spring. C'est le
-- filtrage par type ajouté par le plugin. « all » signifie toute catégorie.
-- Noter que le jeu neutre appliqué aux types inconnus n'est pas codé en dur :
-- il émerge de cette colonne, « unknown » n'étant listé que par IN / NOT_IN,
-- les autres types s'appuyant sur « all ».
M.types = {
  { name = "IS_NOT_NULL", keywords = { "IsNotNull", "NotNull" }, args = 0, jpa = true,
    accepts = "all", requires_nullable = true },
  { name = "IS_NULL", keywords = { "IsNull", "Null" }, args = 0, jpa = true,
    accepts = "all", requires_nullable = true },
  { name = "BETWEEN", keywords = { "IsBetween", "Between" }, args = 2, jpa = true,
    accepts = { "numeric", "temporal" } },
  { name = "LESS_THAN", keywords = { "IsLessThan", "LessThan" }, args = 1, jpa = true,
    accepts = { "numeric", "temporal" } },
  { name = "LESS_THAN_EQUAL", keywords = { "IsLessThanEqual", "LessThanEqual" }, args = 1, jpa = true,
    accepts = { "numeric", "temporal" } },
  { name = "GREATER_THAN", keywords = { "IsGreaterThan", "GreaterThan" }, args = 1, jpa = true,
    accepts = { "numeric", "temporal" } },
  { name = "GREATER_THAN_EQUAL", keywords = { "IsGreaterThanEqual", "GreaterThanEqual" }, args = 1, jpa = true,
    accepts = { "numeric", "temporal" } },
  { name = "BEFORE", keywords = { "IsBefore", "Before" }, args = 1, jpa = true,
    accepts = { "temporal" } },
  { name = "AFTER", keywords = { "IsAfter", "After" }, args = 1, jpa = true,
    accepts = { "temporal" } },
  { name = "NOT_LIKE", keywords = { "IsNotLike", "NotLike" }, args = 1, jpa = true,
    accepts = { "string" } },
  { name = "LIKE", keywords = { "IsLike", "Like" }, args = 1, jpa = true,
    accepts = { "string" } },
  { name = "STARTING_WITH", keywords = { "IsStartingWith", "StartingWith", "StartsWith" }, args = 1, jpa = true,
    accepts = { "string" } },
  { name = "ENDING_WITH", keywords = { "IsEndingWith", "EndingWith", "EndsWith" }, args = 1, jpa = true,
    accepts = { "string" } },
  { name = "IS_NOT_EMPTY", keywords = { "IsNotEmpty", "NotEmpty" }, args = 0, jpa = true,
    accepts = { "collection" } },
  { name = "IS_EMPTY", keywords = { "IsEmpty", "Empty" }, args = 0, jpa = true,
    accepts = { "collection" } },
  { name = "NOT_CONTAINING", keywords = { "IsNotContaining", "NotContaining", "NotContains" }, args = 1, jpa = true,
    accepts = { "string" } },
  { name = "CONTAINING", keywords = { "IsContaining", "Containing", "Contains" }, args = 1, jpa = true,
    accepts = { "string" } },
  { name = "NOT_IN", keywords = { "IsNotIn", "NotIn" }, args = 1, jpa = true,
    accepts = { "string", "numeric", "temporal", "boolean", "unknown" } },
  { name = "IN", keywords = { "IsIn", "In" }, args = 1, jpa = true,
    accepts = { "string", "numeric", "temporal", "boolean", "unknown" } },
  { name = "NEAR", keywords = { "IsNear", "Near" }, args = 1, jpa = false,
    accepts = {} },
  { name = "WITHIN", keywords = { "IsWithin", "Within" }, args = 1, jpa = false,
    accepts = {} },
  { name = "REGEX", keywords = { "MatchesRegex", "Matches", "Regex" }, args = 1, jpa = false,
    accepts = {} },
  { name = "EXISTS", keywords = { "Exists" }, args = 0, jpa = false,
    accepts = {} },
  { name = "TRUE", keywords = { "IsTrue", "True" }, args = 0, jpa = true,
    accepts = { "boolean" } },
  { name = "FALSE", keywords = { "IsFalse", "False" }, args = 0, jpa = true,
    accepts = { "boolean" } },
  { name = "NEGATING_SIMPLE_PROPERTY", keywords = { "IsNot", "Not" }, args = 1, jpa = true,
    accepts = "all" },
  { name = "SIMPLE_PROPERTY", keywords = { "Is", "Equals" }, args = 1, jpa = true,
    accepts = "all" },
}

-- Type retenu par défaut quand aucun alias ne correspond, conformément à
-- Part.Type.fromProperty qui retourne SIMPLE_PROPERTY en dernier recours.
M.default_type = M.types[#M.types]
```

- [ ] **Step 4: Lancer pour vérifier le succès**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: `11 réussis, 0 échoués`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/springdata.nvim
git add lua/springdata/grammar.lua tests/grammar_spec.lua
git commit -m "feat(grammar): les 27 types de conditions de Part.Type, ordre ALL préservé"
```

---

### Task 4: `grammar.lua` — catégories de types Java

**Files:**
- Modify: `lua/springdata/grammar.lua`
- Modify: `tests/grammar_spec.lua`

**Interfaces:**
- Produces: `grammar.categories` (table nom de type Java → catégorie), `grammar.collection_types` (liste `{ "List", "Set", "Collection" }`), `grammar.primitives` (table nom → `true`).

**Contexte.** Les catégories sont `string`, `numeric`, `temporal`, `boolean`, `collection`, `unknown`. Le classement d'un type non listé produit `unknown` — c'est le cas des enums, des entités liées et des types personnalisés. La fonction qui applique ce classement vit dans `parser.lua` (Task 5), pas ici : `grammar.lua` ne contient aucune fonction.

- [ ] **Step 1: Écrire les tests**

Ajouter à la fin de `tests/grammar_spec.lua` :

```lua
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
```

- [ ] **Step 2: Lancer pour constater l'échec**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: 6 ÉCHEC signalant des comparaisons contre `nil`.

- [ ] **Step 3: Implémenter**

Ajouter dans `lua/springdata/grammar.lua`, avant le `return M` :

```lua
-- Classement des types Java en catégories, base du filtrage `accepts`.
-- Un type absent de cette table relève de la catégorie « unknown » : enum,
-- entité liée, type personnalisé. Le classement effectif est réalisé par
-- parser.categorize, ce module ne contenant aucune fonction.
M.categories = {
  ["String"] = "string",
  ["char"] = "string",
  ["Character"] = "string",

  ["int"] = "numeric",
  ["long"] = "numeric",
  ["short"] = "numeric",
  ["byte"] = "numeric",
  ["float"] = "numeric",
  ["double"] = "numeric",
  ["Integer"] = "numeric",
  ["Long"] = "numeric",
  ["Short"] = "numeric",
  ["Byte"] = "numeric",
  ["Float"] = "numeric",
  ["Double"] = "numeric",
  ["BigDecimal"] = "numeric",
  ["BigInteger"] = "numeric",

  ["LocalDate"] = "temporal",
  ["LocalTime"] = "temporal",
  ["LocalDateTime"] = "temporal",
  ["Instant"] = "temporal",
  ["ZonedDateTime"] = "temporal",
  ["OffsetDateTime"] = "temporal",
  ["Date"] = "temporal",
  ["Timestamp"] = "temporal",
  ["Year"] = "temporal",
  ["YearMonth"] = "temporal",

  ["boolean"] = "boolean",
  ["Boolean"] = "boolean",
}

-- Conteneurs reconnus comme catégorie « collection » lorsqu'ils portent des
-- paramètres génériques : List<T>, Set<T>, Collection<T>.
M.collection_types = { "List", "Set", "Collection" }

-- Un primitif ne peut jamais être null : IsNull / IsNotNull sont exclus,
-- indépendamment de la catégorie. `boolean` et `Boolean` partagent la
-- catégorie « boolean » mais seul le second accepte IsNull.
M.primitives = {
  ["int"] = true,
  ["long"] = true,
  ["short"] = true,
  ["byte"] = true,
  ["float"] = true,
  ["double"] = true,
  ["char"] = true,
  ["boolean"] = true,
}
```

- [ ] **Step 4: Lancer pour vérifier le succès**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: `17 réussis, 0 échoués`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/springdata.nvim
git add lua/springdata/grammar.lua tests/grammar_spec.lua
git commit -m "feat(grammar): catégories de types Java pour le filtrage des mots-clés"
```

---

### Task 5: `parser.lua` — primitives de découpage

**Files:**
- Create: `lua/springdata/parser.lua`
- Create: `tests/parser_spec.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Produces: `parser.split_on_keyword(text, keyword) -> table`, `parser.ends_with(s, suffix) -> boolean`, `parser.decapitalize(s) -> string`, `parser.strip_ignore_case(part) -> string, boolean`, `parser.categorize(java_type) -> string`.

**Contexte crucial.** `split_on_keyword` réimplémente `PartTree.KEYWORD_TEMPLATE = "(%s)(?=(\p{Lu}|\P{InBASIC_LATIN}))"`. Lua n'a ni lookahead ni classes Unicode : la fonction cherche le mot-clé littéralement puis vérifie **manuellement** que le caractère suivant est une majuscule ASCII. C'est cette règle, et elle seule, qui résout la collision `andrew` — le découpage ne consulte jamais la liste des champs.

Comportement à reproduire exactement : `"AndId"` découpé sur `"And"` donne `{ "", "Id" }`, un segment vide en tête que l'appelant filtrera comme le fait `StringUtils::hasText` côté Java. `"NameAnd"` n'est pas découpé, le `And` final n'étant suivi d'aucune majuscule.

`decapitalize` reproduit `java.beans.Introspector.decapitalize` : si les deux premiers caractères sont des majuscules, la chaîne est renvoyée inchangée — c'est ce qui préserve les acronymes comme `URL`.

- [ ] **Step 1: Écrire les tests**

Créer `tests/parser_spec.lua` :

```lua
local t = require("harness")
local parser = require("springdata.parser")

t.describe("parser › split_on_keyword", function()
  t.it("découpe quand le mot-clé est suivi d'une majuscule", function()
    t.eq(parser.split_on_keyword("NameAndAge", "And"), { "Name", "Age" })
  end)

  t.it("ne découpe pas quand la suite est en minuscule", function()
    t.eq(parser.split_on_keyword("andrewAge", "And"), { "andrewAge" })
    t.eq(parser.split_on_keyword("AndrewAge", "And"), { "AndrewAge" })
  end)

  t.it("ne découpe que sur les occurrences valides", function()
    t.eq(parser.split_on_keyword("AndrewAndAge", "And"), { "Andrew", "Age" })
  end)

  t.it("ne découpe pas sur un mot-clé en fin de chaîne", function()
    t.eq(parser.split_on_keyword("NameAnd", "And"), { "NameAnd" })
  end)

  t.it("produit un segment vide en tête comme le split de Java", function()
    t.eq(parser.split_on_keyword("AndId", "And"), { "", "Id" })
  end)

  t.it("gère les occurrences multiples", function()
    t.eq(parser.split_on_keyword("AAndBAndC", "And"), { "A", "B", "C" })
  end)

  t.it("renvoie la chaîne intacte en l'absence du mot-clé", function()
    t.eq(parser.split_on_keyword("Name", "And"), { "Name" })
  end)
end)

t.describe("parser › ends_with", function()
  t.it("reconnaît un suffixe", function()
    t.eq(parser.ends_with("ageBetween", "Between"), true)
  end)

  t.it("rejette un non-suffixe", function()
    t.eq(parser.ends_with("ageLessThanEqual", "LessThan"), false)
    t.eq(parser.ends_with("ageLessThanEqual", "LessThanEqual"), true)
  end)

  t.it("rejette un suffixe plus long que la chaîne", function()
    t.eq(parser.ends_with("Is", "IsNotNull"), false)
  end)
end)

t.describe("parser › decapitalize", function()
  t.it("abaisse la première lettre", function()
    t.eq(parser.decapitalize("Name"), "name")
  end)

  t.it("préserve les acronymes comme Introspector.decapitalize", function()
    t.eq(parser.decapitalize("URL"), "URL")
    t.eq(parser.decapitalize("ID"), "ID")
  end)

  t.it("laisse une chaîne vide intacte", function()
    t.eq(parser.decapitalize(""), "")
  end)

  t.it("laisse une chaîne déjà en minuscule intacte", function()
    t.eq(parser.decapitalize("name"), "name")
  end)
end)

t.describe("parser › strip_ignore_case", function()
  t.it("retire IgnoreCase et le signale", function()
    local part, found = parser.strip_ignore_case("nameContainingIgnoreCase")
    t.eq(part, "nameContaining")
    t.eq(found, true)
  end)

  t.it("retire la variante IgnoringCase", function()
    local part, found = parser.strip_ignore_case("nameIgnoringCase")
    t.eq(part, "name")
    t.eq(found, true)
  end)

  t.it("ne signale rien en l'absence du motif", function()
    local part, found = parser.strip_ignore_case("nameContaining")
    t.eq(part, "nameContaining")
    t.eq(found, false)
  end)
end)

t.describe("parser › categorize", function()
  t.it("classe les types connus", function()
    t.eq(parser.categorize("String"), "string")
    t.eq(parser.categorize("int"), "numeric")
    t.eq(parser.categorize("LocalDate"), "temporal")
    t.eq(parser.categorize("Boolean"), "boolean")
  end)

  t.it("reconnaît les conteneurs génériques", function()
    t.eq(parser.categorize("List<Order>"), "collection")
    t.eq(parser.categorize("Set<String>"), "collection")
    t.eq(parser.categorize("Collection<Long>"), "collection")
  end)

  t.it("classe en unknown les enums et entités liées", function()
    t.eq(parser.categorize("Status"), "unknown")
    t.eq(parser.categorize("AddressEntity"), "unknown")
  end)

  t.it("ignore les paramètres génériques d'un type non conteneur", function()
    t.eq(parser.categorize("Optional<String>"), "unknown")
  end)
end)
```

- [ ] **Step 2: Enregistrer la nouvelle spec**

Dans `tests/run.lua`, remplacer :

```lua
local specs = {
  "grammar_spec",
}
```

par :

```lua
local specs = {
  "grammar_spec",
  "parser_spec",
}
```

- [ ] **Step 3: Lancer pour constater l'échec**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: échec au chargement, `module 'springdata.parser' not found`.

- [ ] **Step 4: Implémenter**

Créer `lua/springdata/parser.lua` :

```lua
-- Analyse d'une chaîne de derived query method, éventuellement incomplète.
--
-- Ce module est du Lua pur : il ne référence jamais `vim` et ne dépend ni de
-- Neovim ni de jdtls, ce qui le rend testable sous un interpréteur nu.
--
-- Le pipeline reproduit PartTree. Le découpage ne consulte jamais la liste
-- des champs : celle-ci sert uniquement à valider les propriétés obtenues.
local grammar = require("springdata.grammar")

local M = {}

--- Découpe `text` autour de `keyword`, à la manière de PartTree.split.
---
--- Réimplémentation de KEYWORD_TEMPLATE = "(%s)(?=(\p{Lu}|\P{InBASIC_LATIN}))".
--- Lua n'ayant pas de lookahead, la vérification que le mot-clé est suivi
--- d'une majuscule est faite à la main. La classe \P{InBASIC_LATIN}, qui vise
--- les identifiants CJK, est délibérément écartée — voir §5.5 de la spec.
---
--- C'est cette règle de casse, et elle seule, qui résout la collision
--- `andrew` : dans « andrewAge », le And est suivi d'un `r` minuscule.
---
--- Un segment vide en tête est conservé, comme le fait Pattern.split côté
--- Java ; c'est à l'appelant de le filtrer.
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

--- Vrai si `s` se termine par `suffix`.
function M.ends_with(s, suffix)
  return #s >= #suffix and s:sub(-#suffix) == suffix
end

--- Reproduit java.beans.Introspector.decapitalize.
--- Une chaîne dont les deux premiers caractères sont des majuscules est
--- renvoyée intacte, ce qui préserve les acronymes (« URL » reste « URL »).
function M.decapitalize(s)
  if s == "" then
    return s
  end
  if #s > 1 and s:sub(1, 1):match("%u") and s:sub(2, 2):match("%u") then
    return s
  end
  return s:sub(1, 1):lower() .. s:sub(2)
end

--- Retire le motif Ignor(ing|e)Case d'une part et signale sa présence.
--- Doit être appelé AVANT la détection du type, comme le fait Part :
--- detectAndSetIgnoreCase précède Type.fromProperty.
function M.strip_ignore_case(part)
  for _, keyword in ipairs(grammar.ignore_case) do
    local s, e = part:find(keyword, 1, true)
    if s then
      return part:sub(1, s - 1) .. part:sub(e + 1), true
    end
  end
  return part, false
end

--- Classe un type Java dans l'une des catégories du filtrage.
--- Tout type non reconnu relève de « unknown » : enum, entité liée, type
--- personnalisé. Seuls List, Set et Collection donnent « collection ».
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

return M
```

- [ ] **Step 5: Lancer pour vérifier le succès**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: `38 réussis, 0 échoués`.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/springdata.nvim
git add lua/springdata/parser.lua tests/parser_spec.lua tests/run.lua
git commit -m "feat(parser): primitives de découpage fidèles à PartTree.KEYWORD_TEMPLATE"
```

---

### Task 6: `parser.lua` — analyse du sujet

**Files:**
- Modify: `lua/springdata/parser.lua`
- Modify: `tests/parser_spec.lua`

**Interfaces:**
- Produces: `parser.parse_subject(source) -> subject, predicate_source`. `subject` vaut `{ introducer, category, distinct, max_results, has_by }` ou `nil` si aucun introducteur ne correspond. `predicate_source` est la portion après `By`, ou `nil` si `By` n'a pas encore été tapé.

**Contexte.** Le motif Java est `^(find|read|get|query|search|stream|count|exists|delete|remove)((\p{Lu}.*?))??By`. Le groupe médian est **optionnel et réticent** : le moteur essaie d'abord sans lui — `By` doit alors suivre immédiatement l'introducteur — puis avec, auquel cas le premier caractère doit être une majuscule et l'on retient le **premier** `By` rencontré. Conséquence à ne pas manquer : `findbyName` ne correspond à rien, `by` en minuscule n'étant ni `By` ni un début de groupe valide.

La limitation `(Distinct)?(First|Top)(\d*)?` s'applique au début du groupe médian et **uniquement à la catégorie `query`**. `Distinct` précède `First`/`Top`. Sans nombre, `First`/`Top` valent 1.

- [ ] **Step 1: Écrire les tests**

Ajouter à la fin de `tests/parser_spec.lua` :

```lua
t.describe("parser › parse_subject", function()
  t.it("reconnaît un sujet minimal", function()
    local subject, predicate = parser.parse_subject("findByName")
    t.eq(subject.introducer, "find")
    t.eq(subject.category, "query")
    t.eq(subject.distinct, false)
    t.eq(subject.max_results, nil)
    t.eq(subject.has_by, true)
    t.eq(predicate, "Name")
  end)

  t.it("reconnaît toutes les catégories d'introducteurs", function()
    t.eq(parser.parse_subject("countByName").category, "count")
    t.eq(parser.parse_subject("existsByName").category, "exists")
    t.eq(parser.parse_subject("deleteByName").category, "delete")
    t.eq(parser.parse_subject("removeByName").category, "delete")
    t.eq(parser.parse_subject("streamByName").category, "query")
  end)

  t.it("accepte un type de domaine entre l'introducteur et By", function()
    local subject, predicate = parser.parse_subject("findUserByName")
    t.eq(subject.introducer, "find")
    t.eq(predicate, "Name")
  end)

  t.it("détecte Distinct", function()
    local subject = parser.parse_subject("findDistinctByName")
    t.eq(subject.distinct, true)
  end)

  t.it("détecte First et Top sans nombre comme une limite de 1", function()
    t.eq(parser.parse_subject("findFirstByName").max_results, 1)
    t.eq(parser.parse_subject("findTopByName").max_results, 1)
  end)

  t.it("détecte First et Top avec un nombre", function()
    t.eq(parser.parse_subject("findFirst10ByName").max_results, 10)
    t.eq(parser.parse_subject("findTop5ByName").max_results, 5)
  end)

  t.it("accepte Distinct avant First, dans l'ordre imposé par Spring", function()
    local subject = parser.parse_subject("findDistinctTop5ByName")
    t.eq(subject.distinct, true)
    t.eq(subject.max_results, 5)
  end)

  t.it("n'applique pas la limitation aux catégories count, exists et delete", function()
    t.eq(parser.parse_subject("countByName").max_results, nil)
    t.eq(parser.parse_subject("existsByName").max_results, nil)
    t.eq(parser.parse_subject("deleteByName").max_results, nil)
  end)

  t.it("détecte Distinct sur count malgré l'absence de limitation", function()
    local subject = parser.parse_subject("countDistinctByName")
    t.eq(subject.distinct, true)
    t.eq(subject.max_results, nil)
  end)

  t.it("signale un sujet encore incomplet", function()
    local subject, predicate = parser.parse_subject("findDistinct")
    t.eq(subject.has_by, false)
    t.eq(predicate, nil)
  end)

  t.it("retient le premier By, le groupe médian étant réticent", function()
    local _, predicate = parser.parse_subject("findByStandByFlag")
    t.eq(predicate, "StandByFlag")
  end)

  t.it("rejette un By en minuscule, comme le motif Java", function()
    local subject, predicate = parser.parse_subject("findbyName")
    t.eq(subject.has_by, false)
    t.eq(predicate, nil)
  end)

  t.it("renvoie nil si aucun introducteur ne correspond", function()
    t.eq(parser.parse_subject("fetchByName"), nil)
  end)
end)
```

- [ ] **Step 2: Lancer pour constater l'échec**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: 13 ÉCHEC, `attempt to index a nil value` — `parse_subject` n'existe pas.

- [ ] **Step 3: Implémenter**

Ajouter dans `lua/springdata/parser.lua`, avant le `return M` :

```lua
--- Extrait la limitation First/Top du groupe médian du sujet.
--- Reproduit LIMITED_QUERY_TEMPLATE, qui impose l'ordre Distinct puis
--- First/Top et ne s'applique qu'à la catégorie « query ».
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

--- Analyse le sujet et renvoie le reste, c'est-à-dire le prédicat.
---
--- Reproduit PREFIX_TEMPLATE :
---   ^(find|read|…|remove)((\p{Lu}.*?))??By
--- Le groupe médian étant optionnel et réticent, on essaie d'abord sans lui
--- — By collé à l'introducteur —, puis avec, en exigeant une majuscule en
--- première position et en retenant le premier By rencontré.
---
--- Renvoie nil si aucun introducteur ne correspond ; l'appelant traite alors
--- la chaîne entière comme un prédicat, comme le fait PartTree.
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
      }, predicate
    end
  end

  return nil
end
```

- [ ] **Step 4: Lancer pour vérifier le succès**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: `51 réussis, 0 échoués`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/springdata.nvim
git add lua/springdata/parser.lua tests/parser_spec.lua
git commit -m "feat(parser): analyse du sujet, limitation Distinct/First/Top"
```

---

### Task 7: `parser.lua` — détection du type de condition

**Files:**
- Modify: `lua/springdata/parser.lua`
- Modify: `tests/parser_spec.lua`

**Interfaces:**
- Produces: `parser.detect_type(part) -> type_entry, raw_property`. `type_entry` est une entrée de `grammar.types`, `raw_property` la part privée de son suffixe.

**Contexte.** Reproduit `Part.Type.fromProperty` : on parcourt `grammar.types` **dans l'ordre** et l'on retient le premier type dont un alias satisfait `endsWith` sur la part. En dernier recours, `SIMPLE_PROPERTY` avec la part entière comme propriété.

Le test décisif est `ageLessThanEqual` : `LESS_THAN` précède `LESS_THAN_EQUAL` dans la liste, mais `"ageLessThanEqual"` ne se **termine** pas par `"LessThan"`, donc le test échoue et `LESS_THAN_EQUAL` l'emporte. Aucune règle de plus longue correspondance n'est nécessaire — l'ordre plus `endsWith` suffisent.

- [ ] **Step 1: Écrire les tests**

Ajouter à la fin de `tests/parser_spec.lua` :

```lua
t.describe("parser › detect_type", function()
  local function name_of(part)
    local ty = parser.detect_type(part)
    return ty.name
  end

  t.it("retombe sur SIMPLE_PROPERTY sans mot-clé", function()
    local ty, property = parser.detect_type("name")
    t.eq(ty.name, "SIMPLE_PROPERTY")
    t.eq(property, "name")
  end)

  t.it("distingue GreaterThanEqual de GreaterThan", function()
    t.eq(name_of("ageGreaterThan"), "GREATER_THAN")
    t.eq(name_of("ageGreaterThanEqual"), "GREATER_THAN_EQUAL")
  end)

  t.it("distingue LessThanEqual de LessThan", function()
    t.eq(name_of("ageLessThan"), "LESS_THAN")
    t.eq(name_of("ageLessThanEqual"), "LESS_THAN_EQUAL")
  end)

  t.it("préfère IS_NOT_NULL à IS_NULL, comme l'ordre de ALL l'impose", function()
    t.eq(name_of("nameNotNull"), "IS_NOT_NULL")
    t.eq(name_of("nameIsNotNull"), "IS_NOT_NULL")
    t.eq(name_of("nameNull"), "IS_NULL")
  end)

  t.it("préfère NOT_LIKE à LIKE", function()
    t.eq(name_of("nameNotLike"), "NOT_LIKE")
    t.eq(name_of("nameLike"), "LIKE")
  end)

  t.it("préfère NOT_IN à IN", function()
    t.eq(name_of("ageNotIn"), "NOT_IN")
    t.eq(name_of("ageIn"), "IN")
  end)

  t.it("préfère NOT_CONTAINING à CONTAINING", function()
    t.eq(name_of("nameNotContaining"), "NOT_CONTAINING")
    t.eq(name_of("nameContaining"), "CONTAINING")
  end)

  t.it("reconnaît tous les alias de STARTING_WITH", function()
    t.eq(name_of("nameStartingWith"), "STARTING_WITH")
    t.eq(name_of("nameStartsWith"), "STARTING_WITH")
    t.eq(name_of("nameIsStartingWith"), "STARTING_WITH")
  end)

  t.it("retire le suffixe pour donner la propriété brute", function()
    local _, property = parser.detect_type("ageBetween")
    t.eq(property, "age")
  end)

  t.it("reconnaît les types non supportés par JPA pour pouvoir les signaler", function()
    t.eq(name_of("nameRegex"), "REGEX")
    t.eq(name_of("nameMatches"), "REGEX")
  end)

  t.it("préfère NEGATING_SIMPLE_PROPERTY à SIMPLE_PROPERTY", function()
    t.eq(name_of("nameNot"), "NEGATING_SIMPLE_PROPERTY")
    t.eq(name_of("nameIs"), "SIMPLE_PROPERTY")
    t.eq(name_of("nameEquals"), "SIMPLE_PROPERTY")
  end)

  t.it("reconnaît BETWEEN et ses deux arguments", function()
    local ty = parser.detect_type("ageBetween")
    t.eq(ty.name, "BETWEEN")
    t.eq(ty.args, 2)
  end)
end)
```

- [ ] **Step 2: Lancer pour constater l'échec**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: 12 ÉCHEC, `attempt to call field 'detect_type' (a nil value)`.

- [ ] **Step 3: Implémenter**

Ajouter dans `lua/springdata/parser.lua`, avant le `return M` :

```lua
--- Détermine le type de condition d'une part et en extrait la propriété brute.
---
--- Reproduit Part.Type.fromProperty : parcours de grammar.types DANS L'ORDRE,
--- premier type dont un alias satisfait endsWith. C'est l'ordre, et non une
--- règle de plus longue correspondance, qui donne le bon résultat :
--- « ageLessThanEqual » ne se termine pas par « LessThan », donc LESS_THAN
--- est écarté au profit de LESS_THAN_EQUAL.
---
--- Sans correspondance, SIMPLE_PROPERTY et la part entière, conformément au
--- dernier `return SIMPLE_PROPERTY` de fromProperty.
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
```

- [ ] **Step 4: Lancer pour vérifier le succès**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: `63 réussis, 0 échoués`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/springdata.nvim
git add lua/springdata/parser.lua tests/parser_spec.lua
git commit -m "feat(parser): détection du type de condition par ordre et endsWith"
```

---

### Task 8: `parser.lua` — `parse` complet

**Files:**
- Modify: `lua/springdata/parser.lua`
- Modify: `tests/parser_spec.lua`

**Interfaces:**
- Consumes: `parser.parse_subject`, `parser.detect_type`, `parser.split_on_keyword`, `parser.strip_ignore_case`, `parser.decapitalize`, `parser.categorize`.
- Produces: `parser.parse(source, fields) -> result`, avec

```lua
result = {
  subject    = { introducer, category, distinct, max_results, has_by },
  predicates = { { property, field, type, ignore_case, connector } },
  order_by   = { { property, direction } },
  params     = { { name, java_type } },
  state      = "subject" | "expect_property" | "after_property"
             | "after_condition" | "order_property" | "order_direction",
  errors     = { { code, message } },
}
```

`fields` est une liste de `{ name, java_type, category, annotations }`, éventuellement vide. `connector` vaut `nil` pour le premier prédicat, `"And"` ou `"Or"` ensuite. Codes d'erreur : `unknown_property`, `duplicate_order_by`, `unsupported_keyword`, `incompatible_type`.

**Contexte.** Ordre du pipeline, non négociable : retrait de `AllIgnor(ing|e)Case` sur le prédicat entier, découpage sur `OrderBy`, découpage sur `Or`, découpage sur `And`, puis par part retrait de `Ignor(ing|e)Case` avant la détection du type. Les segments vides issus des découpages sont filtrés, comme le fait `StringUtils::hasText` côté Java.

Nommage des paramètres : un argument prend le nom de la propriété ; `BETWEEN`, qui en prend deux, produit `<propriété>Start` et `<propriété>End`. Le type d'un paramètre est celui du champ, sauf pour `IN`/`NOT_IN` qui donnent `Collection<Wrapper>` via `grammar.boxed`, et pour les conditions textuelles qui donnent `String`.

- [ ] **Step 1: Écrire les tests**

Ajouter à la fin de `tests/parser_spec.lua` :

```lua
local FIELDS = {
  { name = "id", java_type = "Long", annotations = { "Id" } },
  { name = "name", java_type = "String", annotations = {} },
  { name = "email", java_type = "String", annotations = { "Column(unique = true)" } },
  { name = "age", java_type = "int", annotations = {} },
  { name = "createdAt", java_type = "LocalDateTime", annotations = {} },
  { name = "active", java_type = "boolean", annotations = {} },
  { name = "orders", java_type = "List<Order>", annotations = { "OneToMany" } },
  { name = "andrew", java_type = "String", annotations = {} },
}

local function names_of(list, key)
  local out = {}
  for _, item in ipairs(list) do
    out[#out + 1] = item[key]
  end
  return out
end

t.describe("parser › parse", function()
  t.it("analyse un prédicat simple", function()
    local r = parser.parse("findByName", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.predicates[1].property, "name")
    t.eq(r.predicates[1].type.name, "SIMPLE_PROPERTY")
    t.eq(r.predicates[1].connector, nil)
    t.eq(r.params, { { name = "name", java_type = "String" } })
    t.eq(r.errors, {})
  end)

  t.it("analyse deux prédicats reliés par And", function()
    local r = parser.parse("findByNameAndAge", FIELDS)
    t.eq(names_of(r.predicates, "property"), { "name", "age" })
    t.eq(r.predicates[2].connector, "And")
    t.eq(r.params, {
      { name = "name", java_type = "String" },
      { name = "age", java_type = "int" },
    })
  end)

  t.it("analyse deux prédicats reliés par Or", function()
    local r = parser.parse("findByNameOrAge", FIELDS)
    t.eq(names_of(r.predicates, "property"), { "name", "age" })
    t.eq(r.predicates[2].connector, "Or")
  end)

  t.it("ne découpe pas un champ dont le nom contient And", function()
    local r = parser.parse("findByAndrewAge", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.predicates[1].property, "andrewAge")
    t.eq(r.errors[1].code, "unknown_property")
  end)

  t.it("découpe correctement un champ collisionnant suivi d'un vrai And", function()
    local r = parser.parse("findByAndrewAndAge", FIELDS)
    t.eq(names_of(r.predicates, "property"), { "andrew", "age" })
    t.eq(r.errors, {})
  end)

  t.it("génère deux paramètres pour Between", function()
    local r = parser.parse("findByAgeBetween", FIELDS)
    t.eq(r.params, {
      { name = "ageStart", java_type = "int" },
      { name = "ageEnd", java_type = "int" },
    })
  end)

  t.it("ne génère aucun paramètre pour les conditions à zéro argument", function()
    t.eq(parser.parse("findByNameIsNull", FIELDS).params, {})
    t.eq(parser.parse("findByActiveTrue", FIELDS).params, {})
    t.eq(parser.parse("findByOrdersIsEmpty", FIELDS).params, {})
  end)

  t.it("type le paramètre de In comme une Collection du wrapper", function()
    t.eq(parser.parse("findByAgeIn", FIELDS).params, {
      { name = "age", java_type = "Collection<Integer>" },
    })
    t.eq(parser.parse("findByNameIn", FIELDS).params, {
      { name = "name", java_type = "Collection<String>" },
    })
  end)

  t.it("détecte IgnoreCase sans perturber le type", function()
    local r = parser.parse("findByNameContainingIgnoreCase", FIELDS)
    t.eq(r.predicates[1].type.name, "CONTAINING")
    t.eq(r.predicates[1].property, "name")
    t.eq(r.predicates[1].ignore_case, true)
  end)

  t.it("retire AllIgnoreCase avant tout découpage", function()
    local r = parser.parse("findByNameAllIgnoreCaseAndAge", FIELDS)
    t.eq(names_of(r.predicates, "property"), { "name", "age" })
  end)

  t.it("analyse un tri avec direction", function()
    local r = parser.parse("findByNameOrderByAgeDesc", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.order_by, { { property = "age", direction = "Desc" } })
  end)

  t.it("analyse un tri sans direction explicite", function()
    local r = parser.parse("findByNameOrderByAge", FIELDS)
    t.eq(r.order_by, { { property = "age", direction = nil } })
  end)

  t.it("analyse un tri sur plusieurs propriétés", function()
    local r = parser.parse("findByNameOrderByAgeAscIdDesc", FIELDS)
    t.eq(r.order_by, {
      { property = "age", direction = "Asc" },
      { property = "id", direction = "Desc" },
    })
  end)

  t.it("signale un double OrderBy", function()
    local r = parser.parse("findByNameOrderByAgeOrderByName", FIELDS)
    t.eq(r.errors[1].code, "duplicate_order_by")
  end)

  t.it("signale un mot-clé non supporté par JPA", function()
    local r = parser.parse("findByNameRegex", FIELDS)
    t.eq(r.errors[1].code, "unsupported_keyword")
  end)

  t.it("signale une condition incompatible avec le type du champ", function()
    local r = parser.parse("findByAgeContaining", FIELDS)
    t.eq(r.errors[1].code, "incompatible_type")
  end)

  t.it("signale une propriété inconnue", function()
    local r = parser.parse("findByUnknownField", FIELDS)
    t.eq(r.errors[1].code, "unknown_property")
  end)

  t.it("tolère une liste de champs vide sans lever d'erreur de propriété", function()
    local r = parser.parse("findByName", {})
    t.eq(r.predicates[1].property, "name")
    t.eq(r.errors, {})
  end)

  t.it("associe le champ résolu au prédicat", function()
    local r = parser.parse("findByEmail", FIELDS)
    t.eq(r.predicates[1].field.java_type, "String")
    t.eq(r.predicates[1].field.annotations, { "Column(unique = true)" })
  end)
end)

t.describe("parser › états terminaux", function()
  t.it("reste dans le sujet tant que By n'est pas tapé", function()
    t.eq(parser.parse("find", FIELDS).state, "subject")
    t.eq(parser.parse("findDistinct", FIELDS).state, "subject")
  end)

  t.it("attend une propriété juste après By", function()
    t.eq(parser.parse("findBy", FIELDS).state, "expect_property")
  end)

  t.it("attend une propriété après un connecteur", function()
    t.eq(parser.parse("findByNameAnd", FIELDS).state, "expect_property")
    t.eq(parser.parse("findByNameOr", FIELDS).state, "expect_property")
  end)

  t.it("suit une propriété sans condition", function()
    t.eq(parser.parse("findByName", FIELDS).state, "after_property")
  end)

  t.it("suit une condition explicite", function()
    t.eq(parser.parse("findByNameContaining", FIELDS).state, "after_condition")
    t.eq(parser.parse("findByAgeBetween", FIELDS).state, "after_condition")
  end)

  t.it("attend une propriété de tri après OrderBy", function()
    t.eq(parser.parse("findByNameOrderBy", FIELDS).state, "order_property")
  end)

  t.it("attend une direction après une propriété de tri", function()
    t.eq(parser.parse("findByNameOrderByAge", FIELDS).state, "order_direction")
    t.eq(parser.parse("findByNameOrderByAgeAsc", FIELDS).state, "order_direction")
  end)
end)
```

- [ ] **Step 2: Lancer pour constater l'échec**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: 26 ÉCHEC, `attempt to call field 'parse' (a nil value)`.

- [ ] **Step 3: Implémenter**

Ajouter dans `lua/springdata/parser.lua`, avant le `return M` :

```lua
--- Retire AllIgnor(ing|e)Case du prédicat entier.
--- Doit précéder tout découpage, comme le fait Predicate.detectAndSetAllIgnoreCase.
local function strip_all_ignore_case(predicate)
  for _, keyword in ipairs(grammar.all_ignore_case) do
    local s, e = predicate:find(keyword, 1, true)
    if s then
      return predicate:sub(1, s - 1) .. predicate:sub(e + 1), true
    end
  end
  return predicate, false
end

--- Filtre les segments vides produits par un découpage, à la manière du
--- filter(StringUtils::hasText) appliqué côté Java.
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

--- Vrai si le type de condition accepte la catégorie du champ.
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

--- Construit les paramètres induits par un prédicat.
--- BETWEEN, seul type à deux arguments, produit <propriété>Start et
--- <propriété>End. IN et NOT_IN produisent une Collection du type boxé, un
--- générique Java n'acceptant pas de primitif.
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

--- Analyse la clause de tri.
--- Reproduit OrderBySource : découpage après Asc ou Desc suivi d'une
--- majuscule, direction optionnelle en fin de bloc.
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

--- Détermine l'état terminal, c'est-à-dire ce qui est attendu à la position
--- courante. C'est ce qui distingue ce parser de PartTree, lequel ne traite
--- que des chaînes complètes.
local function terminal_state(source, subject, result, has_order_by)
  if not subject or not subject.has_by then
    return "subject"
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

--- Analyse une chaîne de derived query method, éventuellement incomplète.
---
--- `fields` est une liste de { name, java_type, annotations }. Elle peut être
--- vide : la validation des propriétés est alors désactivée plutôt que de
--- produire du bruit. Elle n'intervient JAMAIS dans le découpage.
function M.parse(source, fields)
  fields = fields or {}

  local result = {
    subject = nil,
    predicates = {},
    order_by = {},
    params = {},
    state = "subject",
    errors = {},
  }

  local subject, predicate_source = M.parse_subject(source)
  result.subject = subject

  if not subject or not subject.has_by then
    result.state = "subject"
    return result
  end

  local predicate, all_ignore_case = strip_all_ignore_case(predicate_source)

  local order_segments = M.split_on_keyword(predicate, grammar.order_by)
  if #order_segments > 2 then
    result.errors[#result.errors + 1] = {
      code = "duplicate_order_by",
      message = "OrderBy ne peut apparaître qu'une seule fois",
    }
  end

  local has_order_by = #order_segments > 1
  if has_order_by then
    result.order_by = parse_order_by(order_segments[2])
  end

  local or_segments = compact(M.split_on_keyword(order_segments[1], "Or"))
  local first = true

  for or_index, or_segment in ipairs(or_segments) do
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
          message = type_entry.name .. " n'est pas supporté par Spring Data JPA",
        }
      end

      if #fields > 0 and not field and property ~= "" then
        result.errors[#result.errors + 1] = {
          code = "unknown_property",
          message = "propriété inconnue : " .. property,
        }
      end

      if field then
        local category = M.categorize(field.java_type)
        if not accepts_category(type_entry, category, field.java_type) then
          result.errors[#result.errors + 1] = {
            code = "incompatible_type",
            message = type_entry.name .. " ne s'applique pas à " .. field.java_type,
          }
        end
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

    -- Le connecteur du premier prédicat du groupe suivant est un Or.
    if or_index < #or_segments then
      first = false
    end
  end

  result.state = terminal_state(source, subject, result, has_order_by)
  return result
end
```

- [ ] **Step 4: Lancer pour vérifier le succès**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: `89 réussis, 0 échoués`.

Si le test « analyse deux prédicats reliés par Or » échoue sur `connector`, corriger la logique d'attribution : le premier élément d'un groupe `Or` autre que le premier groupe porte `"Or"`, tous les suivants dans le même groupe portent `"And"`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/springdata.nvim
git add lua/springdata/parser.lua tests/parser_spec.lua
git commit -m "feat(parser): analyse complète avec états terminaux, paramètres et erreurs"
```

---

### Task 9: `parser.lua` — type de retour

**Files:**
- Modify: `lua/springdata/parser.lua`
- Modify: `tests/parser_spec.lua`

**Interfaces:**
- Produces: `parser.return_type(result, entity_name, opts) -> string`. `opts` accepte `delete_return_type` valant `"void"` (défaut) ou `"long"`.

**Contexte — justification de la règle stricte sur `Optional<T>`.** La table officielle des types de retour dit : *« `Optional<T>` — Expects the query method to return one result at most. More than one result triggers an `IncorrectResultSizeDataAccessException`. »* `Optional<T>` encode donc « au plus un », non « peut être absent » — l'absence étant déjà couverte par `List<T>`, qui renvoie une liste vide et jamais `null`. Émettre `Optional<T>` pour un champ non unique produirait du code qui démarre puis échoue dès la deuxième ligne correspondante.

Ordre d'évaluation : `count` → `long` ; `exists` → `boolean` ; `delete` → `void` ou `long` selon l'option ; `max_results == 1` → `Optional<T>` ; `max_results > 1` → `List<T>` ; prédicat unique, sans `Or`, de type `SIMPLE_PROPERTY`, sur un champ `@Id` ou `@Column(unique = true)` → `Optional<T>` ; sinon `List<T>`.

- [ ] **Step 1: Écrire les tests**

Ajouter à la fin de `tests/parser_spec.lua` :

```lua
t.describe("parser › return_type", function()
  local function rt(source, opts)
    return parser.return_type(parser.parse(source, FIELDS), "UserEntity", opts)
  end

  t.it("donne long pour count", function()
    t.eq(rt("countByName"), "long")
  end)

  t.it("donne boolean pour exists", function()
    t.eq(rt("existsByName"), "boolean")
  end)

  t.it("donne void pour delete par défaut", function()
    t.eq(rt("deleteByName"), "void")
    t.eq(rt("removeByName"), "void")
  end)

  t.it("donne long pour delete si l'option le demande", function()
    t.eq(rt("deleteByName", { delete_return_type = "long" }), "long")
  end)

  t.it("donne Optional pour First et Top sans nombre", function()
    t.eq(rt("findFirstByName"), "Optional<UserEntity>")
    t.eq(rt("findTopByName"), "Optional<UserEntity>")
  end)

  t.it("donne Optional pour la forme explicite Top1", function()
    t.eq(rt("findTop1ByName"), "Optional<UserEntity>")
  end)

  t.it("donne List pour une limite supérieure à un", function()
    t.eq(rt("findTop5ByName"), "List<UserEntity>")
  end)

  t.it("donne Optional pour une égalité sur un champ annoté Id", function()
    t.eq(rt("findById"), "Optional<UserEntity>")
  end)

  t.it("donne Optional pour une égalité sur un champ unique", function()
    t.eq(rt("findByEmail"), "Optional<UserEntity>")
  end)

  t.it("donne List pour un champ non unique", function()
    t.eq(rt("findByName"), "List<UserEntity>")
  end)

  t.it("donne List pour une condition non égalitaire sur un champ unique", function()
    t.eq(rt("findByIdGreaterThan"), "List<UserEntity>")
  end)

  t.it("donne List dès qu'un second prédicat s'ajoute à un champ unique", function()
    t.eq(rt("findByEmailAndName"), "List<UserEntity>")
  end)

  t.it("donne List quand un Or relie les prédicats", function()
    t.eq(rt("findByEmailOrName"), "List<UserEntity>")
  end)
end)
```

- [ ] **Step 2: Lancer pour constater l'échec**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: 13 ÉCHEC, `attempt to call field 'return_type' (a nil value)`.

- [ ] **Step 3: Implémenter**

Ajouter dans `lua/springdata/parser.lua`, avant le `return M` :

```lua
--- Vrai si le champ porte @Id ou @Column(unique = true).
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

--- Déduit le type de retour de la méthode.
---
--- Optional<T> est réservé aux requêtes dont la cardinalité maximale est
--- garantie à un. La table officielle des types de retour est explicite :
--- « Expects the query method to return one result at most. More than one
--- result triggers an IncorrectResultSizeDataAccessException. » Le cas
--- « aucun résultat » est déjà couvert par List<T>, qui renvoie une liste
--- vide et jamais null.
function M.return_type(result, entity_name, opts)
  opts = opts or {}
  local subject = result.subject

  if not subject then
    return "List<" .. entity_name .. ">"
  end

  if subject.category == "count" then
    return "long"
  end
  if subject.category == "exists" then
    return "boolean"
  end
  if subject.category == "delete" then
    return opts.delete_return_type == "long" and "long" or "void"
  end

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
```

- [ ] **Step 4: Lancer pour vérifier le succès**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: `102 réussis, 0 échoués`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/springdata.nvim
git add lua/springdata/parser.lua tests/parser_spec.lua
git commit -m "feat(parser): déduction du type de retour, Optional réservé à la cardinalité un"
```

---

### Task 10: `parser.lua` — propositions filtrées

**Files:**
- Modify: `lua/springdata/parser.lua`
- Modify: `tests/parser_spec.lua`

**Interfaces:**
- Produces: `parser.suggestions(result, fields) -> table`, liste de `{ label, kind, detail }` où `kind` vaut `"property"`, `"keyword"`, `"connector"`, `"direction"` ou `"modifier"`.

**Contexte.** C'est la fonction que `source.lua` consommera. Elle traduit l'état terminal en propositions, en appliquant le filtrage par type. Les types dont `jpa` est faux ne sont jamais proposés. Le jeu neutre appliqué aux champs de catégorie `unknown` n'est pas codé en dur : il découle de la colonne `accepts`, seuls `IN`/`NOT_IN` listant `unknown` et les types généraux valant `"all"`.

- [ ] **Step 1: Écrire les tests**

Ajouter à la fin de `tests/parser_spec.lua` :

```lua
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

  t.it("propose les champs juste après By", function()
    local labels = labels_of(suggest("findBy"))
    for _, name in ipairs({ "id", "name", "email", "age", "createdAt", "active", "orders" }) do
      t.truthy(contains(labels, name), "champ manquant : " .. name)
    end
  end)

  t.it("propose les conditions textuelles sur un champ String", function()
    local labels = labels_of(suggest("findByName"))
    for _, keyword in ipairs({ "Containing", "StartingWith", "EndingWith", "Like", "IsNull" }) do
      t.truthy(contains(labels, keyword), "mot-clé manquant : " .. keyword)
    end
  end)

  t.it("n'offre pas les conditions textuelles sur un champ numérique", function()
    local labels = labels_of(suggest("findByAge"))
    t.eq(contains(labels, "Containing"), false)
    t.eq(contains(labels, "StartingWith"), false)
    t.truthy(contains(labels, "Between"), "Between doit être proposé sur un numérique")
    t.truthy(contains(labels, "GreaterThan"), "GreaterThan doit être proposé")
  end)

  t.it("n'offre pas Between sur un champ String", function()
    local labels = labels_of(suggest("findByName"))
    t.eq(contains(labels, "Between"), false)
    t.eq(contains(labels, "After"), false)
  end)

  t.it("offre After et Before sur un champ temporel", function()
    local labels = labels_of(suggest("findByCreatedAt"))
    t.truthy(contains(labels, "After"), "After doit être proposé")
    t.truthy(contains(labels, "Before"), "Before doit être proposé")
    t.eq(contains(labels, "Containing"), false)
  end)

  t.it("offre True et False sur un booléen, mais pas IsNull sur un primitif", function()
    local labels = labels_of(suggest("findByActive"))
    t.truthy(contains(labels, "True"), "True doit être proposé")
    t.truthy(contains(labels, "False"), "False doit être proposé")
    t.eq(contains(labels, "IsNull"), false)
  end)

  t.it("offre IsEmpty sur une collection uniquement", function()
    t.truthy(contains(labels_of(suggest("findByOrders")), "IsEmpty"), "IsEmpty attendu")
    t.eq(contains(labels_of(suggest("findByName")), "IsEmpty"), false)
  end)

  t.it("n'offre jamais les mots-clés non supportés par JPA", function()
    for _, source in ipairs({ "findByName", "findByAge", "findByCreatedAt", "findByOrders" }) do
      local labels = labels_of(suggest(source))
      for _, forbidden in ipairs({ "Regex", "Matches", "MatchesRegex", "Exists", "Near", "Within" }) do
        t.eq(contains(labels, forbidden), false)
      end
    end
  end)

  t.it("offre les connecteurs et OrderBy après une propriété", function()
    local labels = labels_of(suggest("findByName"))
    t.truthy(contains(labels, "And"), "And attendu")
    t.truthy(contains(labels, "Or"), "Or attendu")
    t.truthy(contains(labels, "OrderBy"), "OrderBy attendu")
  end)

  t.it("offre IgnoreCase après une condition textuelle", function()
    local labels = labels_of(suggest("findByNameContaining"))
    t.truthy(contains(labels, "IgnoreCase"), "IgnoreCase attendu")
  end)

  t.it("n'offre pas IgnoreCase après une condition numérique", function()
    local labels = labels_of(suggest("findByAgeBetween"))
    t.eq(contains(labels, "IgnoreCase"), false)
  end)

  t.it("offre les directions après une propriété de tri", function()
    local labels = labels_of(suggest("findByNameOrderByAge"))
    t.truthy(contains(labels, "Asc"), "Asc attendu")
    t.truthy(contains(labels, "Desc"), "Desc attendu")
  end)

  t.it("offre les champs après OrderBy", function()
    local labels = labels_of(suggest("findByNameOrderBy"))
    t.truthy(contains(labels, "age"), "champ attendu après OrderBy")
  end)

  t.it("offre les modificateurs dans le sujet", function()
    local labels = labels_of(suggest("find"))
    t.truthy(contains(labels, "Distinct"), "Distinct attendu")
    t.truthy(contains(labels, "First"), "First attendu")
    t.truthy(contains(labels, "Top"), "Top attendu")
    t.truthy(contains(labels, "By"), "By attendu")
  end)

  t.it("n'offre pas First et Top après count", function()
    local labels = labels_of(suggest("count"))
    t.eq(contains(labels, "First"), false)
    t.eq(contains(labels, "Top"), false)
    t.truthy(contains(labels, "Distinct"), "Distinct reste proposé")
  end)

  t.it("réduit les propositions au jeu neutre sur un type inconnu", function()
    local fields = { { name = "status", java_type = "Status", annotations = {} } }
    local labels = labels_of(parser.suggestions(parser.parse("findByStatus", fields), fields))
    for _, keyword in ipairs({ "Is", "Equals", "Not", "IsNull", "IsNotNull", "In", "NotIn" }) do
      t.truthy(contains(labels, keyword), "jeu neutre incomplet : " .. keyword)
    end
    for _, keyword in ipairs({ "Containing", "Between", "True", "IsEmpty" }) do
      t.eq(contains(labels, keyword), false)
    end
  end)
end)
```

- [ ] **Step 2: Lancer pour constater l'échec**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: 16 ÉCHEC, `attempt to call field 'suggestions' (a nil value)`.

- [ ] **Step 3: Implémenter**

Ajouter dans `lua/springdata/parser.lua`, avant le `return M` :

```lua
--- Traduit l'état terminal en propositions, filtrage par type appliqué.
---
--- Les types dont `jpa` est faux ne sont jamais proposés : REGEX et EXISTS
--- lèveraient « Unsupported keyword » au démarrage, NEAR et WITHIN sont hors
--- périmètre v1.
---
--- Le jeu neutre des types inconnus n'est pas codé ici : il découle de la
--- colonne `accepts` de grammar.types.
function M.suggestions(result, fields)
  fields = fields or {}
  local out = {}

  local function add(label, kind, detail)
    out[#out + 1] = { label = label, kind = kind, detail = detail }
  end

  local function add_fields()
    for _, field in ipairs(fields) do
      add(field.name, "property", field.java_type)
    end
  end

  local state = result.state

  if state == "subject" then
    local category = result.subject and result.subject.category or "query"
    add(grammar.distinct, "modifier", "résultats distincts")
    if category == "query" then
      for _, keyword in ipairs(grammar.limiting) do
        add(keyword, "modifier", "limite le nombre de résultats")
      end
    end
    add("By", "modifier", "introduit le prédicat")
    return out
  end

  if state == "expect_property" or state == "order_property" then
    add_fields()
    return out
  end

  if state == "order_direction" then
    for _, direction in ipairs(grammar.directions) do
      add(direction, "direction", "sens du tri")
    end
    add_fields()
    return out
  end

  -- after_property et after_condition
  local last = result.predicates[#result.predicates]
  local field = last and last.field
  local category = field and M.categorize(field.java_type) or nil
  local java_type = field and field.java_type or nil

  if state == "after_property" and category then
    for _, type_entry in ipairs(grammar.types) do
      if type_entry.jpa and accepts_category(type_entry, category, java_type) then
        for _, keyword in ipairs(type_entry.keywords) do
          add(keyword, "keyword", type_entry.name)
        end
      end
    end
  end

  if state == "after_condition" and category == "string" then
    add("IgnoreCase", "keyword", "comparaison insensible à la casse")
  end

  for _, connector in ipairs(grammar.connectors) do
    add(connector, "connector", "relie deux prédicats")
  end
  add(grammar.order_by, "connector", "clause de tri")

  return out
end
```

- [ ] **Step 4: Lancer pour vérifier le succès**

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: `118 réussis, 0 échoués`.

Si le test du jeu neutre échoue en proposant `IsEmpty` sur un type inconnu, vérifier que `IS_EMPTY.accepts` vaut bien `{ "collection" }` et non `"all"`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/springdata.nvim
git add lua/springdata/parser.lua tests/parser_spec.lua
git commit -m "feat(parser): propositions filtrées par catégorie de type"
```

---

### Task 11: `entity.lua` — résolution du type générique

**Files:**
- Create: `lua/springdata/entity.lua`

**Interfaces:**
- Produces: `entity.resolve_entity_name(bufnr) -> string|nil`, `entity.is_repository(bufnr) -> boolean`.

**Contexte.** Premier module dépendant de Neovim, donc hors de la suite `luajit`. Il s'agit d'extraire `T` depuis `extends …Repository<T, ID>` **par treesitter, jamais par regex**. La vérification se fait à la main dans Neovim.

Structure de l'arbre pour `public interface UserRepository extends JpaRepository<UserEntity, Integer> {}` : `interface_declaration` contient un `extends_interfaces` (nommé `super_interfaces` dans certaines versions du parser) contenant un `type_list`, contenant un `generic_type`, lequel contient un `type_identifier` et un `type_arguments`. Le premier enfant nommé de `type_arguments` est `T`.

- [ ] **Step 1: Écrire le module**

Créer `lua/springdata/entity.lua` :

```lua
-- Résolution de l'entité d'un repository Spring Data et extraction de ses
-- champs. Seul module à dépendre à la fois de treesitter et de jdtls.
local M = {}

--- Requête treesitter isolant le premier argument générique d'une interface
--- qui étend un type dont le nom se termine par « Repository ».
---
--- Le parser java expose `extends_interfaces` sur les versions récentes et
--- `super_interfaces` sur les plus anciennes ; la requête tolère les deux en
--- ne contraignant pas le nœud intermédiaire.
local QUERY = [[
(interface_declaration
  (_
    (type_list
      (generic_type
        (type_identifier) @repo_name
        (type_arguments
          (_) @entity_name)))))
]]

local function iter_matches(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "java")
  if not ok or not parser then
    return nil
  end

  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local query_ok, query = pcall(vim.treesitter.query.parse, "java", QUERY)
  if not query_ok then
    return nil
  end

  return query, tree:root()
end

--- Nom de l'entité d'un repository, ou nil si le buffer n'en est pas un.
function M.resolve_entity_name(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local query, root = iter_matches(bufnr)
  if not query then
    return nil
  end

  for _, match in query:iter_matches(root, bufnr, 0, -1) do
    local repo_name, entity_name
    for id, nodes in pairs(match) do
      local node = type(nodes) == "table" and nodes[1] or nodes
      local capture = query.captures[id]
      local text = vim.treesitter.get_node_text(node, bufnr)
      if capture == "repo_name" then
        repo_name = text
      elseif capture == "entity_name" and not entity_name then
        entity_name = text
      end
    end

    if repo_name and repo_name:match("Repository$") and entity_name then
      return entity_name
    end
  end

  return nil
end

--- Vrai si le buffer contient une interface étendant un *Repository.
function M.is_repository(bufnr)
  return M.resolve_entity_name(bufnr) ~= nil
end

return M
```

- [ ] **Step 2: Vérifier à la main dans Neovim**

Créer un fichier de test `/tmp/UserRepository.java` :

```java
package com.example;

import org.springframework.data.jpa.repository.JpaRepository;

public interface UserRepository extends JpaRepository<UserEntity, Integer> {
}
```

L'ouvrir puis évaluer :

```
:lua vim.opt.rtp:prepend("/Users/sam/Projects/springdata.nvim")
:lua print(require("springdata.entity").resolve_entity_name(0))
```

Expected: `UserEntity`

Vérifier aussi qu'un buffer Java quelconque renvoie `nil` :

```
:lua print(vim.inspect(require("springdata.entity").resolve_entity_name(0)))
```

Expected: `nil` sur un fichier qui n'est pas un repository.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/springdata.nvim
git add lua/springdata/entity.lua
git commit -m "feat(entity): résolution du type générique du repository par treesitter"
```

---

### Task 12: `entity.lua` — champs, annotations et cache

**Files:**
- Modify: `lua/springdata/entity.lua`

**Interfaces:**
- Produces: `entity.fields(entity_name, callback)` où `callback(fields)` reçoit une liste de `{ name, java_type, annotations }` ; `entity.invalidate(entity_name)`; `entity.setup_autocmds()`.

**Contexte.** jdtls localise, treesitter extrait. `documentSymbol` ne remonte pas les annotations, or `@Id` et `@Column(unique = true)` décident du type de retour. La séquence est donc : `workspace/symbol` sur le nom de l'entité pour obtenir l'URI du fichier, puis chargement de ce fichier dans un buffer et extraction treesitter des `field_declaration` avec leurs `modifiers` — c'est là que vivent les annotations dans l'arbre Java.

Le cache est indexé par nom d'entité et invalidé sur `BufWritePost` du fichier concerné.

- [ ] **Step 1: Écrire le module**

Ajouter dans `lua/springdata/entity.lua`, avant le `return M` :

```lua
-- Cache des champs, indexé par nom d'entité. Invalidé sur BufWritePost du
-- fichier de l'entité, via setup_autocmds.
local cache = {}
local uri_index = {}

--- Extrait les champs d'un buffer Java : nom, type et annotations.
--- Les annotations vivent dans le nœud `modifiers` du `field_declaration`.
local FIELDS_QUERY = [[
(field_declaration) @field
]]

local function extract_fields(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "java")
  if not ok or not parser then
    return {}
  end

  local tree = parser:parse()[1]
  if not tree then
    return {}
  end

  local query_ok, query = pcall(vim.treesitter.query.parse, "java", FIELDS_QUERY)
  if not query_ok then
    return {}
  end

  local fields = {}

  for _, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
    local java_type, name
    local annotations = {}

    for child in node:iter_children() do
      local kind = child:type()
      if kind == "modifiers" then
        for modifier in child:iter_children() do
          local mtype = modifier:type()
          if mtype == "annotation" or mtype == "marker_annotation" then
            -- Le texte inclut le @ initial, que l'on retire pour ne garder
            -- que « Id » ou « Column(unique = true) ».
            local text = vim.treesitter.get_node_text(modifier, bufnr)
            annotations[#annotations + 1] = (text:gsub("^@%s*", ""))
          end
        end
      elseif kind == "variable_declarator" then
        local name_node = child:field("name")[1]
        if name_node then
          name = vim.treesitter.get_node_text(name_node, bufnr)
        end
      elseif java_type == nil and kind ~= "modifiers" then
        java_type = vim.treesitter.get_node_text(child, bufnr)
      end
    end

    if name and java_type then
      -- Un champ statique ou transient n'est pas persisté : il ne doit pas
      -- apparaître dans les propositions.
      local skip = false
      for child in node:iter_children() do
        if child:type() == "modifiers" then
          local text = vim.treesitter.get_node_text(child, bufnr)
          if text:find("static", 1, true) or text:find("transient", 1, true) then
            skip = true
          end
        end
      end

      if not skip then
        fields[#fields + 1] = {
          name = name,
          java_type = java_type,
          annotations = annotations,
        }
      end
    end
  end

  return fields
end

--- Charge le fichier d'une URI dans un buffer et en extrait les champs.
local function fields_from_uri(uri)
  local bufnr = vim.uri_to_bufnr(uri)
  vim.fn.bufload(bufnr)
  return extract_fields(bufnr)
end

--- Récupère les champs d'une entité, en passant par le cache.
--- jdtls localise le fichier via workspace/symbol, treesitter en extrait le
--- contenu — documentSymbol ne remonterait pas les annotations.
function M.fields(entity_name, callback)
  if cache[entity_name] then
    callback(cache[entity_name])
    return
  end

  local clients = vim.lsp.get_clients({ name = "jdtls" })
  if #clients == 0 then
    callback({})
    return
  end

  clients[1]:request("workspace/symbol", { query = entity_name }, function(err, results)
    if err or not results or #results == 0 then
      callback({})
      return
    end

    local uri
    for _, symbol in ipairs(results) do
      if symbol.name == entity_name then
        uri = symbol.location and symbol.location.uri
        break
      end
    end

    if not uri then
      callback({})
      return
    end

    local fields = fields_from_uri(uri)
    cache[entity_name] = fields
    uri_index[vim.uri_to_fname(uri)] = entity_name
    callback(fields)
  end)
end

--- Vide l'entrée de cache d'une entité, ou tout le cache si aucun nom donné.
function M.invalidate(entity_name)
  if entity_name then
    cache[entity_name] = nil
  else
    cache = {}
    uri_index = {}
  end
end

--- Invalide le cache d'une entité dès que son fichier est sauvegardé.
function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("SpringDataEntityCache", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.java",
    callback = function(args)
      local entity_name = uri_index[args.file]
      if entity_name then
        M.invalidate(entity_name)
      end
    end,
  })
end
```

- [ ] **Step 2: Vérifier à la main dans Neovim**

Dans un projet Spring Boot 3 réel, ouvrir un repository, attendre que jdtls soit attaché (`:LspInfo`), puis :

```
:lua vim.opt.rtp:prepend("/Users/sam/Projects/springdata.nvim")
:lua local e = require("springdata.entity"); e.fields(e.resolve_entity_name(0), function(f) print(vim.inspect(f)) end)
```

Expected: une liste de champs avec `name`, `java_type` et `annotations`, le champ identifiant portant `"Id"` dans ses annotations.

Vérifier ensuite l'invalidation : modifier l'entité, la sauvegarder, relancer la commande et constater que la nouvelle liste reflète le changement.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/springdata.nvim
git add lua/springdata/entity.lua
git commit -m "feat(entity): extraction des champs et annotations, cache invalidé à la sauvegarde"
```

---

### Task 13: `source.lua` — provider blink.cmp

**Files:**
- Create: `lua/springdata/source.lua`

**Interfaces:**
- Consumes: `parser.parse`, `parser.suggestions`, `parser.return_type`, `entity.resolve_entity_name`, `entity.fields`.
- Produces: `source.new(opts)`, `source:enabled()`, `source:get_completions(ctx, callback)`.

**Contexte.** Le contrat blink.cmp est celui déjà utilisé par `lua/spell_source.lua` dans la config : un module exposant `new`, `enabled` et `get_completions(ctx, callback)`, ce dernier renvoyant une fonction d'annulation.

Point de comportement imposé par la spec : **aucune proposition de méthode complète tant qu'aucune propriété n'est sélectionnée.** Le moteur officiel de Spring Tools émet un `findBy` nu que ses propres mainteneurs considèrent comme du bruit (`spring-projects/spring-tools#1014`). Tant que `state` vaut `subject` ou `expect_property`, on ne propose que des fragments ; la signature complète n'apparaît qu'à partir de `after_property`.

- [ ] **Step 1: Écrire le module**

Créer `lua/springdata/source.lua` :

```lua
-- Source blink.cmp pour les derived query methods Spring Data.
local parser = require("springdata.parser")
local entity = require("springdata.entity")

local M = {}

function M.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = M })
end

--- Actif uniquement dans un buffer Java dont l'interface étend un *Repository.
function M:enabled()
  if vim.bo.filetype ~= "java" then
    return false
  end
  return entity.is_repository(0)
end

--- Fragment de méthode déjà tapé, à gauche du curseur.
--- On remonte jusqu'au début de l'identifiant, en s'arrêtant sur tout ce qui
--- ne peut pas faire partie d'un nom de méthode.
local function current_prefix(ctx)
  local line = ctx.line or ""
  local col = ctx.cursor and ctx.cursor[2] or #line
  local before = line:sub(1, col)
  return before:match("([%a%d_]+)$") or ""
end

--- Construit le snippet LuaSnip de la signature complète.
--- Les tabstops portent sur les noms de paramètres, pour permettre de les
--- renommer immédiatement après insertion.
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

function M:get_completions(ctx, callback)
  local cancelled = false
  local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()

  local entity_name = entity.resolve_entity_name(bufnr)
  if not entity_name then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return function() end
  end

  local prefix = current_prefix(ctx)

  entity.fields(entity_name, function(fields)
    if cancelled then
      return
    end

    local result = parser.parse(prefix, fields)
    local items = {}

    -- Fragments : propriétés, mots-clés, connecteurs, directions.
    for _, suggestion in ipairs(parser.suggestions(result, fields)) do
      items[#items + 1] = {
        label = prefix .. suggestion.label,
        filterText = prefix .. suggestion.label,
        insertText = prefix .. suggestion.label,
        labelDetails = { description = suggestion.detail },
        kind = suggestion.kind == "property" and 5 or 14, -- Field / Keyword
        sortText = string.format("%02d%s", suggestion.kind == "property" and 1 or 2, suggestion.label),
      }
    end

    -- Signature complète : jamais avant qu'une propriété soit sélectionnée,
    -- pour ne pas reproduire le `findBy` nu de Spring Tools (issue #1014).
    local complete_states = {
      after_property = true,
      after_condition = true,
      order_direction = true,
    }

    if complete_states[result.state] and #result.predicates > 0 and #result.errors == 0 then
      local return_type = parser.return_type(result, entity_name, self.opts)
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

return M
```

- [ ] **Step 2: Créer le point d'entrée du plugin**

Créer `lua/springdata/init.lua` :

```lua
-- Complétion des derived query methods Spring Data JPA.
local M = {}

local defaults = {
  -- Type de retour des méthodes deleteBy / removeBy : "void" ou "long".
  delete_return_type = "void",
}

M.opts = defaults

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", defaults, opts or {})
  require("springdata.entity").setup_autocmds()
  return M.opts
end

return M
```

- [ ] **Step 3: Vérifier à la main dans Neovim**

Ajouter temporairement le provider à la configuration blink, dans une session de test :

```
:lua vim.opt.rtp:prepend("/Users/sam/Projects/springdata.nvim")
:lua require("springdata").setup({})
:lua require("blink.cmp").setup({ sources = { default = { "lsp", "path", "snippets", "buffer", "spell", "springdata" }, providers = { springdata = { name = "SpringData", module = "springdata.source", score_offset = 100 } } } })
```

Dans le repository de test, taper `findByNameCont` puis déclencher la complétion.

Expected: un item dont la documentation affiche `List<UserEntity> findByNameContaining(String name);`, et dont la validation insère cette signature avec le curseur sur `name`.

- [ ] **Step 4: Commit**

```bash
cd ~/Projects/springdata.nvim
git add lua/springdata/source.lua lua/springdata/init.lua
git commit -m "feat(source): provider blink.cmp avec insertion en snippet LuaSnip"
```

---

### Task 14: Intégration à la config et README

**Files:**
- Create: `/Users/sam/.dotfiles/nvim/plugin/config/springdata.lua`
- Modify: `/Users/sam/.dotfiles/nvim/lua/config/completion.lua`
- Modify: `README.md`

**Contexte.** La config nvim est liée en symlinks fichier par fichier vers `~/.dotfiles/nvim`. Le nouveau fichier `plugin/config/springdata.lua` impose de relancer `store` une fois, puis sur les autres machines. C'est le seul fichier ajouté côté dotfiles.

- [ ] **Step 1: Créer le fichier de câblage**

Créer `/Users/sam/.dotfiles/nvim/plugin/config/springdata.lua` :

```lua
-- springdata.nvim — complétion des derived query methods Spring Data JPA.
-- Développé en local ; commenter la ligne rtp le jour d'une bascule vers
-- vim.pack, sur le modèle de weather.lua.
vim.opt.rtp:prepend("/Users/sam/Projects/springdata.nvim")

require("springdata").setup({
  delete_return_type = "void",
})
```

- [ ] **Step 2: Déclarer le provider blink**

Dans `/Users/sam/.dotfiles/nvim/lua/config/completion.lua`, remplacer la ligne :

```lua
    default = { "lsp", "path", "snippets", "buffer", "spell" },
```

par :

```lua
    default = { "lsp", "path", "snippets", "buffer", "spell", "springdata" },
```

Puis ajouter dans la table `providers`, après le bloc `spell` :

```lua
      springdata = {
        name = "SpringData",
        module = "springdata.source",
        -- Score élevé : dans une interface de repository, ces propositions
        -- sont plus pertinentes que celles de jdtls, qui ne connaît pas la
        -- grammaire des derived query methods.
        score_offset = 100,
        min_keyword_length = 3,
      },
```

- [ ] **Step 3: Écrire le README**

Remplacer le contenu de `README.md` :

````markdown
# springdata.nvim

Complétion des *derived query methods* Spring Data JPA dans Neovim, à la manière
d'IntelliJ IDEA.

En tapant `findByNameCont` dans une interface qui étend `JpaRepository<UserEntity, Integer>`,
le plugin propose `Containing` puis insère :

```java
List<UserEntity> findByNameContaining(String name);
```

## Fonctionnement

La grammaire n'est pas transcrite depuis la documentation mais depuis le code de
Spring Data — `PartTree.java`, `Part.java` et `OrderBySource.java` côté
`spring-data-commons`, `JpaQueryCreator.java` côté `spring-data-jpa`. La table de
mots-clés de la documentation est celle de `commons`, partagée par tous les stores,
et contient des mots-clés que JPA rejette au démarrage.

Le découpage de la chaîne suit strictement l'algorithme de Spring : un mot-clé ne
découpe que s'il est suivi d'une majuscule. C'est ce qui fait que `findByAndrewAge`
n'est pas découpé sur `And`. La liste des champs de l'entité sert à valider et à
proposer, jamais à arbitrer un découpage — le plugin interprète donc la chaîne
exactement comme Spring l'interprétera à l'exécution.

## Installation

```lua
vim.opt.rtp:prepend("/chemin/vers/springdata.nvim")
require("springdata").setup({})
```

Puis déclarer la source dans blink.cmp :

```lua
sources = {
  default = { "lsp", "path", "snippets", "buffer", "springdata" },
  providers = {
    springdata = {
      name = "SpringData",
      module = "springdata.source",
      score_offset = 100,
      min_keyword_length = 3,
    },
  },
}
```

## Options

| Option | Défaut | Description |
|---|---|---|
| `delete_return_type` | `"void"` | Type de retour des méthodes `deleteBy` / `removeBy`. `"long"` pour renvoyer le nombre de lignes supprimées. |

## Type de retour

| Cas | Type |
|---|---|
| `countBy…` | `long` |
| `existsBy…` | `boolean` |
| `deleteBy…` / `removeBy…` | `void`, ou `long` selon l'option |
| `findFirstBy…` / `findTopBy…` / `findTop1By…` | `Optional<T>` |
| `findTop5By…` | `List<T>` |
| Prédicat unique, sans `Or`, égalité sur un champ `@Id` ou `@Column(unique = true)` | `Optional<T>` |
| Tous les autres cas | `List<T>` |

`Optional<T>` est délibérément réservé aux requêtes dont la cardinalité maximale est
garantie à un. La documentation Spring est explicite : *« Expects the query method to
return one result at most. More than one result triggers an
`IncorrectResultSizeDataAccessException`. »* Le cas « aucun résultat » est déjà
couvert par `List<T>`, qui renvoie une liste vide et jamais `null`. Émettre
`Optional<T>` pour un champ non unique produirait du code qui démarre puis échoue dès
la deuxième ligne correspondante.

## Hors périmètre

Volontairement absents de cette version :

- **Propriétés imbriquées** (`findByAddress_ZipCode`) — impose la résolution récursive
  des entités liées, pour un usage marginal.
- **Projections** et types de retour personnalisés.
- **`Streamable`**, types Vavr.
- **Paramètres `Pageable` / `Sort`**, types de retour `Page` / `Slice` / `Window`.
- **`Near` / `Within`** — en JPA ce sont des mots-clés de recherche vectorielle, non
  géospatiaux ; ils exigent un champ `Vector` et un paramètre `Score` ou
  `Range<Score>`. Le `findByLocationNear(Point, Distance)` géospatial relève de Spring
  Data MongoDB.

Jamais proposés, car ils font échouer le démarrage de l'application :

- **`Regex` / `Matches` / `MatchesRegex`** et **`Exists` en condition** — présents dans
  la table de la documentation, héritée de `spring-data-commons`, mais absents du
  `switch` de `JpaQueryCreator`, qui lève alors
  `IllegalArgumentException: Unsupported keyword`.

## Tests

```bash
luajit tests/run.lua
```

`grammar.lua` et `parser.lua` ne référencent jamais `vim` : la suite s'exécute sans
Neovim. `entity.lua` et `source.lua` se vérifient à la main dans un projet Spring
Boot.
````

- [ ] **Step 4: Vérifier l'intégration complète**

Relancer la suite pour s'assurer qu'aucune régression n'est introduite :

Run: `cd ~/Projects/springdata.nvim && luajit tests/run.lua`
Expected: `118 réussis, 0 échoués`.

Relancer `store` depuis les dotfiles pour créer le symlink du nouveau fichier, puis ouvrir Neovim sur un repository du projet de test et vérifier que la complétion fonctionne sans configuration manuelle.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/springdata.nvim
git add README.md
git commit -m "docs: README avec périmètre, options et justification du type de retour"

cd /Users/sam/.dotfiles
git add nvim/plugin/config/springdata.lua nvim/lua/config/completion.lua
git commit -m "feat(nvim): câble springdata.nvim comme source blink.cmp"
```

---

## Auto-revue du plan

**Couverture de la spec.** §3 périmètre → Task 14 (README). §4 architecture → structure des fichiers, Tasks 1 à 14. §5.1 sujet → Task 6. §5.2 modificateurs → Tasks 2 et 6. §5.3 conditions → Tasks 3 et 7. §5.4 casse et tri → Tasks 2, 5 et 8. §5.5 découpage → Task 5. §6 contrat du parser et cas limites → Tasks 8 et 10, les 16 cas limites du §6 étant tous repris comme tests. §7 filtrage par type → Tasks 4 et 10. §8 type de retour → Task 9. §9 entity → Tasks 11 et 12. §10 source → Task 13. §11 tests → Task 1. §12 ordre de réalisation → respecté. §13 contraintes d'environnement → contraintes globales et Task 12 (`vim.uri_to_bufnr`, pas de `vim.loop`).

**Cohérence des noms.** `parser.parse`, `parser.parse_subject`, `parser.detect_type`, `parser.split_on_keyword`, `parser.ends_with`, `parser.decapitalize`, `parser.strip_ignore_case`, `parser.categorize`, `parser.suggestions`, `parser.return_type` — identiques entre définitions et usages. `entity.resolve_entity_name`, `entity.is_repository`, `entity.fields`, `entity.invalidate`, `entity.setup_autocmds` — idem. `grammar.types`, `grammar.introducers`, `grammar.categories`, `grammar.primitives`, `grammar.boxed`, `grammar.collection_types`, `grammar.limiting`, `grammar.directions`, `grammar.connectors`, `grammar.ignore_case`, `grammar.all_ignore_case`, `grammar.distinct`, `grammar.order_by`, `grammar.default_type` — tous définis en Tasks 2 à 4 avant leur premier usage en Task 5.

**Points de vigilance signalés à l'implémenteur.** L'attribution du `connector` en Task 8 est le point le plus délicat du plan : le test correspondant est explicite et l'étape 4 indique quoi corriger en cas d'échec. La fonction locale `accepts_category`, définie en Task 8, est réutilisée en Task 10 — elle doit rester accessible dans la portée du module, donc être déclarée avant `M.suggestions`.
