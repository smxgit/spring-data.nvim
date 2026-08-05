-- Pure data transcribed from Spring Data's sources.
-- This module contains no function and never references `vim`.
--
-- Sources:
--   spring-data-commons: PartTree.java, Part.java, OrderBySource.java
--   spring-data-jpa:     JpaQueryCreator.java
local M = {}

-- PartTree: QUERY_PATTERN, COUNT_PATTERN, EXISTS_PATTERN, DELETE_PATTERN.
-- No keyword is a prefix of another, so the first match is unambiguous.
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

-- PartTree.Subject: DISTINCT, LIMITING_QUERY_PATTERN.
-- LIMITED_QUERY_TEMPLATE enforces the order Distinct then First/Top, and
-- only applies to the "query" category.
M.distinct = "Distinct"
M.limiting = { "First", "Top" }

-- PartTree.Predicate: ORDER_BY. OrderBySource: DIRECTION_KEYWORDS.
M.order_by = "OrderBy"
M.directions = { "Asc", "Desc" }

-- Predicate splitting: Or first, then And.
M.connectors = { "And", "Or" }

-- Part.IGNORE_CASE = "Ignor(ing|e)Case" and Predicate.ALL_IGNORE_CASE.
-- Ordered longest to shortest so the literal search doesn't truncate the
-- longer variant.
M.ignore_case = { "IgnoringCase", "IgnoreCase" }
M.all_ignore_case = { "AllIgnoringCase", "AllIgnoreCase" }

-- Needed to type In / NotIn parameters as Collection<Integer> rather than
-- Collection<int>, since a Java generic can't take a primitive.
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

-- Part.Type, transcribed in the order of the ALL constant.
--
-- ORDER IS SIGNIFICANT. The Java code carries the comment "Need to list
-- them again explicitly as the order is important". The parser keeps the
-- first type whose alias satisfies endsWith: this order is what makes
-- "NotNull" resolve to IS_NOT_NULL and not IS_NULL, "NotLike" to NOT_LIKE
-- and not LIKE, "NotIn" to NOT_IN and not IN.
--
-- `jpa` field: false for types the parser must still recognise but that
-- the source will never offer.
--   REGEX, EXISTS: absent from JpaQueryCreator's switch, raise
--                  "Unsupported keyword" at startup.
--   NEAR, WITHIN:  supported by JPA, but for vector search, with a Score
--                  or Range<Score> parameter. Out of scope for v1.
--
-- `accepts` field: the ONLY data that does not come from Spring. This is
-- the plugin's own type filtering. "all" means every category. Note the
-- neutral set applied to unknown types is not hardcoded: it emerges from
-- this column, "unknown" being listed only by IN / NOT_IN, every other
-- type relying on "all".
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

-- Default type when no alias matches, per Part.Type.fromProperty, which
-- returns SIMPLE_PROPERTY as a last resort.
M.default_type = M.types[#M.types]

-- Java type -> category mapping, the basis of `accepts` filtering. A type
-- absent from this table falls under the "unknown" category: enum,
-- related entity, custom type. The actual classification is done by
-- parser.categorize; this module contains no function.
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

-- Containers recognised as the "collection" category when carrying generic
-- parameters: List<T>, Set<T>, Collection<T>.
M.collection_types = { "List", "Set", "Collection" }

-- A primitive can never be null: IsNull / IsNotNull are excluded regardless
-- of category. `boolean` and `Boolean` share the "boolean" category but
-- only the latter accepts IsNull.
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

return M
