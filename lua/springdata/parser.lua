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

  -- Correctif : un utilisateur qui vient de taper OrderBy attend une
  -- propriété de tri. split_on_keyword rejette ce cas car OrderBy, en toute
  -- fin de chaîne, n'est suivi d'aucun caractère — donc d'aucune majuscule —
  -- si bien que has_order_by reste faux (même règle que pour "andrewAge",
  -- ici appliquée à une position où elle ne devrait pas s'appliquer).
  if M.ends_with(source, grammar.order_by) then
    return "order_property"
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
---
--- Contrat sur les états d'attente. Dans les états "expect_property" et
--- "order_property", le dernier élément de `predicates` (et le paramètre,
--- l'erreur qui peuvent l'accompagner) peut être un FRAGMENT de ce que
--- l'utilisateur est encore en train de taper, et non une propriété
--- achevée. Ceci n'est pas un bug à corriger dans les données : un And, Or
--- ou OrderBy en toute fin de chaîne est indécidable depuis la seule chaîne
--- — champ complet nommé "…And", ou connecteur pas encore suivi d'une
--- propriété ? — et trancher demanderait de consulter `fields` au moment du
--- découpage, ce que ce module ne fait jamais (voir plus haut). Le
--- découpage suit donc la même règle que PartTree/split_on_keyword : le
--- mot-clé reste attaché au texte s'il n'est suivi d'aucune majuscule, y
--- compris quand il n'est suivi de rien. Les consommateurs DOIVENT se fier à
--- `state` pour savoir si le dernier prédicat est fiable, jamais au seul
--- contenu de `predicates`.
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

      -- Un mot-clé que JPA ne supporte pas du tout n'a pas de sens à évaluer
      -- vis-à-vis du type du champ : ce serait signaler deux fois la même
      -- faute, la seconde fois pour un motif faux (le champ n'y est pour
      -- rien). Seul un mot-clé JPA valide peut être incompatible avec un type.
      if field and type_entry.jpa then
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
    if not result.subject then
      for _, intro in ipairs(grammar.introducers) do
        add(intro.keyword, "modifier", intro.category)
      end
    end
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

return M
