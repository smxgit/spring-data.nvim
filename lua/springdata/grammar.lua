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

return M
