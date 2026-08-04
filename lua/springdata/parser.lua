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

return M
