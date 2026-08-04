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
