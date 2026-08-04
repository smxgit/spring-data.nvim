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
