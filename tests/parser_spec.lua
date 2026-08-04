local t = require("harness")
local parser = require("spring-data.parser")

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

  t.it("reconnaît tous les alias de CONTAINING et extrait la propriété", function()
    local ty1, prop1 = parser.detect_type("nameContaining")
    t.eq(ty1.name, "CONTAINING")
    t.eq(prop1, "name")

    local ty2, prop2 = parser.detect_type("nameIsContaining")
    t.eq(ty2.name, "CONTAINING")
    t.eq(prop2, "name")

    local ty3, prop3 = parser.detect_type("nameContains")
    t.eq(ty3.name, "CONTAINING")
    t.eq(prop3, "name")
  end)

  t.it("reconnaît tous les alias de STARTING_WITH", function()
    local ty1, prop1 = parser.detect_type("nameStartingWith")
    t.eq(ty1.name, "STARTING_WITH")
    t.eq(prop1, "name")

    local ty2, prop2 = parser.detect_type("nameStartsWith")
    t.eq(ty2.name, "STARTING_WITH")
    t.eq(prop2, "name")

    local ty3, prop3 = parser.detect_type("nameIsStartingWith")
    t.eq(ty3.name, "STARTING_WITH")
    t.eq(prop3, "name")
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

  t.it("gère le cas limite : une part qui EST exactement un mot-clé", function()
    local ty, property = parser.detect_type("Between")
    t.eq(ty.name, "BETWEEN")
    t.eq(property, "")
  end)
end)

local FIELDS = {
  { name = "id", java_type = "Long", annotations = { "Id" } },
  { name = "name", java_type = "String", annotations = {} },
  { name = "email", java_type = "String", annotations = { "Column(unique = true)" } },
  { name = "age", java_type = "int", annotations = {} },
  { name = "createdAt", java_type = "LocalDateTime", annotations = {} },
  { name = "active", java_type = "boolean", annotations = {} },
  { name = "orders", java_type = "List<Order>", annotations = { "OneToMany" } },
  { name = "andrew", java_type = "String", annotations = {} },
  -- Champs dont le nom se termine par un mot-clé de découpage, pour couvrir
  -- la même collision que "andrew" mais sur And/Or/OrderBy en fin de chaîne.
  { name = "logicalAnd", java_type = "String", annotations = {} },
  { name = "sortOrderBy", java_type = "String", annotations = {} },
  { name = "isOr", java_type = "String", annotations = {} },
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

  -- Régression : le découpage ne consulte JAMAIS la liste des champs (voir
  -- contraintes du plan). "findByLogicalAnd" est donc indécidable depuis la
  -- seule chaîne — And en cours de frappe, ou champ "logicalAnd" complet —
  -- et split_on_keyword tranche comme PartTree : and/Or/OrderBy en toute
  -- fin de chaîne, non suivis d'une majuscule, restent attachés au texte.
  -- Quand le champ correspondant existe réellement, ce choix est le bon :
  -- la propriété complète est retrouvée sans erreur.
  t.it("reconnaît un champ dont le nom se termine par And", function()
    local r = parser.parse("findByLogicalAnd", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.predicates[1].property, "logicalAnd")
    t.eq(r.errors, {})
  end)

  t.it("reconnaît un champ dont le nom se termine par OrderBy", function()
    local r = parser.parse("findBySortOrderBy", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.predicates[1].property, "sortOrderBy")
    t.eq(r.errors, {})
  end)

  t.it("reconnaît un champ dont le nom se termine par Or", function()
    local r = parser.parse("findByIsOr", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.predicates[1].property, "isOr")
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
    -- Un mot-clé hors JPA ne doit pas en plus être signalé comme
    -- incompatible avec le type du champ : ce serait une seconde erreur
    -- factuellement fausse (le problème n'est pas le type de "name").
    t.eq(#r.errors, 1)
  end)

  t.it("signale une condition incompatible avec le type du champ", function()
    local r = parser.parse("findByAgeContaining", FIELDS)
    t.eq(r.errors[1].code, "incompatible_type")
  end)

  t.it("signale une propriété inconnue", function()
    local r = parser.parse("findByUnknownField", FIELDS)
    t.eq(r.errors[1].code, "unknown_property")
  end)

  -- JpaQueryCreator.upperIfIgnoreCase : « Unable to ignore case of int
  -- types, the property 'age' must reference a String ». Sans cette
  -- vérification, la source proposait une signature qui empêche
  -- l'application de démarrer.
  t.it("signale IgnoreCase sur un champ non textuel", function()
    local r = parser.parse("findByAgeIgnoreCase", FIELDS)
    t.eq(r.errors, { { code = "incompatible_type", message = "IgnoreCase ne s'applique pas à int" } })
  end)

  t.it("accepte IgnoreCase sur un champ textuel", function()
    t.eq(parser.parse("findByNameIgnoreCase", FIELDS).errors, {})
    t.eq(parser.parse("findByNameContainingIgnoreCase", FIELDS).errors, {})
  end)

  -- AllIgnor(ing|e)Case donne IgnoreCaseType.WHEN_POSSIBLE aux parts, et
  -- cette branche de upperIfIgnoreCase n'applique upper() que si le type
  -- s'y prête : elle ne lève jamais. La signaler serait une fausse erreur.
  t.it("ne signale pas AllIgnoreCase sur un champ non textuel", function()
    t.eq(parser.parse("findByNameAndAgeAllIgnoreCase", FIELDS).errors, {})
  end)

  t.it("signale une propriété de tri inconnue", function()
    local r = parser.parse("findByNameOrderByBogusAsc", FIELDS)
    t.eq(r.errors, { { code = "unknown_property", message = "propriété de tri inconnue : bogus" } })
  end)

  t.it("signale une propriété de tri manquante", function()
    local r = parser.parse("findByNameOrderByAsc", FIELDS)
    t.eq(r.errors[1].code, "missing_order_property")
    -- Faute structurelle : détectable même sans liste de champs.
    t.eq(parser.parse("findByNameOrderByAsc", {}).errors[1].code, "missing_order_property")
  end)

  t.it("valide chaque propriété de tri d'une clause multiple", function()
    t.eq(parser.parse("findByNameOrderByAgeAscIdDesc", FIELDS).errors, {})
    t.eq(#parser.parse("findByNameOrderByAgeAscBogusDesc", FIELDS).errors, 1)
  end)

  t.it("ne valide pas les propriétés de tri sans liste de champs", function()
    t.eq(parser.parse("findByNameOrderByBogusAsc", {}).errors, {})
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

  t.it("porte le connecteur encore en cours de frappe comme fragment du dernier prédicat", function()
    -- "findByNameAnd" est indécidable depuis la seule chaîne : soit un And
    -- pas encore suivi de propriété, soit un champ nommé "nameAnd" complet.
    -- Le découpage ne consultant JAMAIS la liste des champs (contrainte du
    -- plan), split_on_keyword tranche comme PartTree : And en toute fin de
    -- chaîne, non suivi de majuscule, reste collé au texte. Le fragment
    -- "nameAnd" atterrit donc bien dans predicates/params/errors ; c'est
    -- `state` — "expect_property" ici — qui indique au consommateur de ne
    -- pas s'y fier tel quel. Voir le contrat documenté sur M.parse.
    local r = parser.parse("findByNameAnd", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.predicates[1].property, "nameAnd")
    t.eq(r.errors, { { code = "unknown_property", message = "propriété inconnue : nameAnd" } })
    t.eq(r.params, { { name = "nameAnd", java_type = "Object" } })
    t.eq(r.state, "expect_property")
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

  t.it("porte le OrderBy encore en cours de frappe comme fragment du dernier prédicat", function()
    -- Même indécidabilité que pour And/Or ci-dessus : "findByNameOrderBy"
    -- pourrait être un champ complet nommé "nameOrderBy". split_on_keyword
    -- rejette le découpage (OrderBy en toute fin de chaîne, aucune majuscule
    -- ne suit), donc "NameOrderBy" reste une part entière et devient le
    -- prédicat SIMPLE_PROPERTY "nameOrderBy", avec son erreur
    -- unknown_property et son paramètre associés. `state` reste correct
    -- ("order_property") grâce au seul correctif retenu dans terminal_state.
    local r = parser.parse("findByNameOrderBy", FIELDS)
    t.eq(#r.predicates, 1)
    t.eq(r.predicates[1].property, "nameOrderBy")
    t.eq(r.order_by, {})
    t.eq(r.errors, { { code = "unknown_property", message = "propriété inconnue : nameOrderBy" } })
    t.eq(r.params, { { name = "nameOrderBy", java_type = "Object" } })
    t.eq(r.state, "order_property")
  end)

  t.it("attend une direction après une propriété de tri", function()
    t.eq(parser.parse("findByNameOrderByAge", FIELDS).state, "order_direction")
    t.eq(parser.parse("findByNameOrderByAgeAsc", FIELDS).state, "order_direction")
  end)
end)

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

  t.it("propose tous les introducteurs sur une chaîne vide", function()
    local labels = labels_of(suggest(""))
    for _, keyword in ipairs({ "find", "count", "exists", "delete" }) do
      t.truthy(contains(labels, keyword), "introducteur manquant : " .. keyword)
    end
  end)

  t.it("restreint les introducteurs à ceux que le fragment commence", function()
    -- Avant la complétion par fragment, les dix introducteurs étaient
    -- proposés quel que soit le texte tapé ; « fin » n'en commence qu'un.
    local labels = labels_of(suggest("fin"))
    t.truthy(contains(labels, "find"), "find attendu")
    for _, keyword in ipairs({ "count", "exists", "delete", "By", "Distinct" }) do
      t.eq(contains(labels, keyword), false)
    end
  end)

  t.it("n'offre plus les introducteurs une fois l'un d'eux reconnu", function()
    local labels = labels_of(suggest("find"))
    t.eq(contains(labels, "find"), false)
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

-- Complétion d'un jeton partiel : le scénario même du plugin. Tant que la
-- fin de la chaîne ne résout pas, les propositions doivent REMPLACER ce
-- fragment au lieu de s'y ajouter — sans quoi taper un caractère de plus
-- faisait disparaître toute proposition utile, ou produisait des absurdités
-- du genre « findDistDistinct ».
t.describe("parser › suggestions sur fragment", function()
  local function suggest(source, fields)
    fields = fields or FIELDS
    return parser.suggestions(parser.parse(source, fields), fields)
  end

  -- Texte réellement inséré : le libellé remplace `replace_length`
  -- caractères en fin de source. Reproduit ce que fait source.lua, pour
  -- pouvoir énoncer les attentes sous leur forme observable.
  local function inserted(source, label, fields)
    for _, s in ipairs(suggest(source, fields)) do
      if s.label == label then
        local text = s.label
        if s.kind == "property" then
          text = text:sub(1, 1):upper() .. text:sub(2)
        end
        return source:sub(1, #source - s.replace_length) .. text
      end
    end
    return nil
  end

  t.it("complète un mot-clé de condition amorcé", function()
    t.eq(inserted("findByNameCont", "Containing"), "findByNameContaining")
    t.eq(inserted("findByNameCont", "Contains"), "findByNameContains")
  end)

  t.it("ne propose que ce que le fragment commence", function()
    local labels = labels_of(suggest("findByNameCont"))
    t.eq(labels, { "Containing", "Contains" })
  end)

  t.it("complète un nom de champ amorcé", function()
    t.eq(inserted("findByNa", "name"), "findByName")
    t.eq(labels_of(suggest("findByNa")), { "name" })
  end)

  t.it("complète un champ dont le nom se termine par un connecteur", function()
    t.eq(inserted("findByLogicalAn", "logicalAnd"), "findByLogicalAnd")
  end)

  t.it("complète un connecteur amorcé après une propriété", function()
    t.eq(inserted("findByNameAn", "And"), "findByNameAnd")
    t.eq(inserted("findByNameOrderB", "OrderBy"), "findByNameOrderBy")
  end)

  t.it("complète un modificateur de sujet sans le dupliquer", function()
    t.eq(inserted("findDist", "Distinct"), "findDistinct")
    t.eq(inserted("findDistinctFir", "First"), "findDistinctFirst")
    t.eq(inserted("findTop5B", "By"), "findTop5By")
  end)

  t.it("ne repropose pas un modificateur déjà posé", function()
    t.eq(contains(labels_of(suggest("findDistinct")), "Distinct"), false)
    t.eq(contains(labels_of(suggest("findFirst")), "First"), false)
    t.truthy(contains(labels_of(suggest("findDistinct")), "By"), "By reste proposé")
  end)

  t.it("ne propose rien sur un fragment qui ne correspond à rien", function()
    t.eq(suggest("findByZzz"), {})
    t.eq(suggest("findByNameZzz"), {})
  end)

  t.it("traite un fragment égal à un nom de champ complet comme achevé", function()
    local r = parser.parse("findByName", FIELDS)
    t.eq(r.fragment, "")
    for _, s in ipairs(parser.suggestions(r, FIELDS)) do
      t.eq(s.replace_length, 0)
    end
    t.eq(inserted("findByName", "Containing"), "findByNameContaining")
    t.eq(inserted("findByName", "And"), "findByNameAnd")
  end)

  t.it("complète une propriété de tri amorcée", function()
    t.eq(inserted("findByNameOrderByNa", "name"), "findByNameOrderByName")
    t.eq(labels_of(suggest("findByNameOrderByNa")), { "name" })
  end)

  t.it("complète une direction de tri amorcée", function()
    t.eq(inserted("findByNameOrderByAgeA", "Asc"), "findByNameOrderByAgeAsc")
    t.eq(inserted("findByNameOrderByAgeDe", "Desc"), "findByNameOrderByAgeDesc")
  end)

  t.it("ne propose pas de seconde direction sur un bloc de tri clos", function()
    t.eq(contains(labels_of(suggest("findByNameOrderByAgeAsc")), "Asc"), false)
    t.truthy(contains(labels_of(suggest("findByNameOrderByAgeAsc")), "name"), "champ attendu")
  end)

  t.it("ne devine aucun fragment sans liste de champs", function()
    -- Sans champs, la validation est désactivée (§6) : rien ne distingue un
    -- fragment d'une propriété achevée. On retombe alors sur l'ancien
    -- comportement — ajouter à la suite — plutôt que de deviner.
    local r = parser.parse("findByNameCont", {})
    t.eq(r.fragment, "")
    local labels = labels_of(parser.suggestions(r, {}))
    t.eq(labels, { "And", "Or", "OrderBy" })
  end)
end)
