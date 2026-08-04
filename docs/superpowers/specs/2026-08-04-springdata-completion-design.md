# springdata.nvim — complétion des derived query methods Spring Data JPA

**Date** : 2026-08-04
**Statut** : design validé, prêt pour le plan d'implémentation

## 1. Objectif

Proposer, dans une interface Spring Data ouverte sous Neovim, la complétion des
*derived query methods* à la manière d'IntelliJ IDEA : en tapant `findByNameCont`
puis en validant, le plugin insère la signature complète

```java
List<UserEntity> findByNameContaining(String name);
```

La complétion propose, selon la position dans la grammaire : les champs de l'entité,
puis les mots-clés de condition compatibles avec le type du champ, puis les
connecteurs et le tri. Le type de retour est déduit du sujet et des prédicats.

Le serveur Spring Boot Tools est présent dans l'installation cible mais sa complétion
spring-data ne produit rien d'exploitable. Le plugin ne s'appuie pas dessus.

## 2. Source de vérité

La documentation seule est insuffisante : sa table de mots-clés est celle de
`spring-data-commons`, partagée par tous les stores, et elle liste des mots-clés que
JPA rejette au démarrage. La spécification s'appuie donc sur trois sources, par ordre
d'autorité décroissante :

1. **`spring-data-commons`** — `PartTree.java`, `Part.java`, `OrderBySource.java` :
   grammaire réellement exécutée (découpage, alias, nombre d'arguments, ordre de
   résolution).
2. **`spring-data-jpa`** — `JpaQueryCreator.java` : mots-clés effectivement supportés
   par JPA, et contraintes de type imposées à l'exécution.
3. **Documentation Spring Data JPA** — pages « Query Creation », « Repository Query
   Keywords », « Repository Query Return Types ».

Toute règle codée dans `grammar.lua` doit être traçable vers l'une de ces sources.
La seule donnée qui n'en provient pas est le filtrage par type (§7), ajout délibéré
du plugin, isolé dans une colonne distincte.

## 3. Périmètre

### Dans la v1

- Introducteurs, modificateurs, conditions, connecteurs, tri.
- Filtrage des mots-clés selon le type du champ.
- Déduction du type de retour.
- Champs de l'entité racine uniquement.

### Hors v1 — à documenter dans le README

- **Propriétés imbriquées** (`findByAddress_ZipCode`) : impose la résolution récursive
  des entités liées, pour un usage marginal.
- **Projections** et types de retour personnalisés.
- **`Streamable`**, types Vavr.
- **Paramètres `Pageable` / `Sort`**, types de retour `Page` / `Slice` / `Window`.
- **`Near` / `Within`** : en JPA ce sont des mots-clés de recherche vectorielle, pas
  géospatiaux ; ils exigent un champ `Vector` et un paramètre `Score` ou
  `Range<Score>` (`JpaQueryCreator` : *« Near/Within keywords must be used with a
  Score or Range<Score> type »*). Le géospatial `findByLocationNear(Point, Distance)`
  relève de Spring Data MongoDB.
- **`Regex` / `Matches` / `MatchesRegex` et `Exists` en condition** : présents dans la
  table de la doc (héritée de commons) mais **absents du `switch` de
  `JpaQueryCreator`**, donc `IllegalArgumentException: Unsupported keyword` au
  démarrage. Le plugin ne doit jamais les proposer.
- **Kotlin name mangling** (troncature au premier `-`) : non pertinent ici.

## 4. Architecture

```
~/Projects/springdata.nvim/
  lua/springdata/
    grammar.lua    -- données pures, aucune logique
    parser.lua     -- pur Lua, aucune dépendance nvim ni jdtls
    entity.lua     -- treesitter + jdtls, cache
    source.lua     -- provider blink.cmp
    init.lua       -- setup()
  tests/
    grammar_spec.lua
    parser_spec.lua
    run.lua        -- runner minimal : `luajit tests/run.lua`
  README.md
```

Dépendances entre modules, strictement descendantes :

```
source.lua  ->  parser.lua  ->  grammar.lua
     |
     +------->  entity.lua  ->  grammar.lua
```

`parser.lua` et `grammar.lua` ne référencent jamais `vim`, ce qui les rend testables
par un interpréteur Lua nu.

### Intégration à la config

Développement en local, sur le modèle de `weather.nvim` : un seul fichier nouveau dans
les dotfiles, `nvim/plugin/config/springdata.lua` :

```lua
vim.opt.rtp:prepend("/Users/sam/Projects/springdata.nvim")
require("springdata").setup({})
```

La ligne `rtp:prepend` sera commentée le jour d'une bascule vers `vim.pack`.
La config nvim étant liée en symlinks fichier par fichier, ce fichier impose de
relancer `store` une fois, puis sur les autres machines.

## 5. `grammar.lua` — données

Aucune fonction. Uniquement des tables.

### 5.1 Sujet

Transcription de `PartTree.PREFIX_TEMPLATE` :

```
^(find|read|get|query|search|stream|count|exists|delete|remove)(\p{Lu}.*?)??By
```

Entre l'introducteur et `By`, Spring accepte **n'importe quoi commençant par une
majuscule** (le `findUserBy…`), pas seulement les modificateurs.

Catégories d'introducteurs :

| Catégorie | Mots-clés |
|---|---|
| `query` | `find`, `read`, `get`, `query`, `search`, `stream` |
| `count` | `count` |
| `exists` | `exists` |
| `delete` | `delete`, `remove` |

### 5.2 Modificateurs

Transcription de `PartTree.Subject` :

- `Distinct` : détecté par simple `contains`, donc positionnable librement.
- `(First|Top)(\d*)?` : `LIMITED_QUERY_TEMPLATE` impose l'ordre
  `(find|read|get|query|search|stream)(Distinct)?(First|Top)(\d*)?(\p{Lu}.*?)??By`.
  **`Distinct` précède `First`/`Top`**, et la limitation n'existe **que pour la
  catégorie `query`** — jamais pour `count`, `exists`, `delete`.
- `First`/`Top` sans nombre ⇒ `maxResults = 1`. Avec nombre ⇒ `maxResults = N`.

### 5.3 Conditions

Transcription littérale de `Part.Type`, **dans l'ordre de la constante `ALL`**, que le
code accompagne du commentaire *« Need to list them again explicitly as the order is
important »*. Le parser retient le **premier type dont un alias satisfait `endsWith`**.

| Type | Alias | `args` | JPA |
|---|---|---|---|
| `IS_NOT_NULL` | `IsNotNull`, `NotNull` | 0 | oui |
| `IS_NULL` | `IsNull`, `Null` | 0 | oui |
| `BETWEEN` | `IsBetween`, `Between` | **2** | oui |
| `LESS_THAN` | `IsLessThan`, `LessThan` | 1 | oui |
| `LESS_THAN_EQUAL` | `IsLessThanEqual`, `LessThanEqual` | 1 | oui |
| `GREATER_THAN` | `IsGreaterThan`, `GreaterThan` | 1 | oui |
| `GREATER_THAN_EQUAL` | `IsGreaterThanEqual`, `GreaterThanEqual` | 1 | oui |
| `BEFORE` | `IsBefore`, `Before` | 1 | oui |
| `AFTER` | `IsAfter`, `After` | 1 | oui |
| `NOT_LIKE` | `IsNotLike`, `NotLike` | 1 | oui |
| `LIKE` | `IsLike`, `Like` | 1 | oui |
| `STARTING_WITH` | `IsStartingWith`, `StartingWith`, `StartsWith` | 1 | oui |
| `ENDING_WITH` | `IsEndingWith`, `EndingWith`, `EndsWith` | 1 | oui |
| `IS_NOT_EMPTY` | `IsNotEmpty`, `NotEmpty` | 0 | oui, collections |
| `IS_EMPTY` | `IsEmpty`, `Empty` | 0 | oui, collections |
| `NOT_CONTAINING` | `IsNotContaining`, `NotContaining`, `NotContains` | 1 | oui |
| `CONTAINING` | `IsContaining`, `Containing`, `Contains` | 1 | oui |
| `NOT_IN` | `IsNotIn`, `NotIn` | 1 | oui |
| `IN` | `IsIn`, `In` | 1 | oui |
| `NEAR` | `IsNear`, `Near` | 1 | **hors v1** |
| `WITHIN` | `IsWithin`, `Within` | 1 | **hors v1** |
| `REGEX` | `MatchesRegex`, `Matches`, `Regex` | 1 | **non supporté** |
| `EXISTS` | `Exists` | 0 | **non supporté** |
| `TRUE` | `IsTrue`, `True` | 0 | oui |
| `FALSE` | `IsFalse`, `False` | 0 | oui |
| `NEGATING_SIMPLE_PROPERTY` | `IsNot`, `Not` | 1 | oui |
| `SIMPLE_PROPERTY` | `Is`, `Equals` | 1 | oui |

L'ordre doit être conservé dans la table Lua, y compris pour les types non proposés :
un utilisateur peut avoir tapé `Regex` à la main, et le parser doit alors le
reconnaître pour signaler qu'il est invalide plutôt que de mal découper la chaîne.
La colonne `jpa` distingue « reconnu par le parser » de « proposé par la source ».

Le défaut, en l'absence de tout alias reconnu, est `SIMPLE_PROPERTY` avec 1 argument.

### 5.4 Casse et tri

- `Ignor(ing|e)Case` : `Part.IGNORE_CASE`, retiré de **chaque part** avant la
  détection du type.
- `AllIgnor(ing|e)Case` : `Predicate.ALL_IGNORE_CASE`, retiré du **prédicat entier**
  avant tout découpage.
- `OrderBy` : `Predicate.ORDER_BY`, une seule occurrence autorisée — au-delà, Spring
  lève *« OrderBy must not be used more than once in a method name »*.
- Tri : `OrderBySource.BLOCK_SPLIT = (?<=Asc|Desc)(?=\p{Lu})`, direction optionnelle
  via `DIRECTION_SPLIT = (.+?)(Asc|Desc)?$`.

### 5.5 Découpage

`PartTree.KEYWORD_TEMPLATE` :

```
(%s)(?=(\p{Lu}|\P{InBASIC_LATIN}))
```

Le mot-clé de découpage doit être **suivi d'une majuscule**. C'est cette règle, et
elle seule, qui résout la collision `andrew` : dans `findByAndrewAge`, `And` est suivi
d'un `r` minuscule, donc aucun découpage n'a lieu. Le découpage **ne consulte jamais
la liste des champs**.

Lua n'ayant ni lookahead ni classes Unicode, ces regex sont réimplémentées à la main
dans `parser.lua`. La restriction à `\p{Lu}` ASCII (`A-Z`) est acceptée : le cas
`\P{InBASIC_LATIN}` vise les identifiants CJK, hors périmètre.

## 6. `parser.lua` — contrat

```lua
parser.parse(source, fields) -> result
```

- `source` : chaîne partielle, p. ex. `"findByNameAndAge"`.
- `fields` : liste de `{ name, java_type, category, annotations }`. Peut être vide —
  le parser dégrade alors la validation sans échouer.

Pipeline, calqué sur `PartTree` et dans le même ordre :

1. Match du sujet ⇒ introducteur, catégorie, `distinct`, `max_results`, présence de `By`.
2. Retrait de `AllIgnor(ing|e)Case` sur le prédicat.
3. Découpage sur `OrderBy`, puis sur `Or`, puis sur `And`.
4. Par part : retrait de `Ignor(ing|e)Case`, puis premier type dont un alias satisfait
   `endsWith`, puis décapitalisation du reste pour obtenir la propriété.
5. Validation de la propriété contre `fields` — **validation seulement**, jamais
   arbitrage du découpage.

Sortie :

```lua
{
  subject   = { introducer, category, distinct, max_results, has_by },
  predicates = { { property, field, type, ignore_case, connector } },
  order_by  = { { property, direction } },
  params    = { { name, java_type } },   -- accumulés dans l'ordre
  state     = "<état terminal>",
  errors    = { { code, message, at } },
}
```

### États terminaux

Le parser traite en permanence des chaînes incomplètes — c'est ce qui le distingue de
`PartTree`, qui ne parse que du complet. L'état terminal indique ce qui est attendu à
la position courante :

| État | Attendu ensuite |
|---|---|
| `subject` | introducteur, `Distinct`, `First`/`Top`, `By` |
| `expect_property` | un champ de l'entité |
| `after_property` | condition compatible, `And`, `Or`, `OrderBy`, ou fin |
| `after_condition` | `IgnoreCase`, `And`, `Or`, `OrderBy`, ou fin |
| `order_property` | un champ de l'entité |
| `order_direction` | `Asc`, `Desc`, un autre champ de tri, ou fin |

### Cas limites à verrouiller par les tests

Écrits **avant** l'implémentation.

- `findByAndrewAge` : pas de découpage sur `And` (minuscule suivante).
- `findByAndrewAndAge` : découpage sur le second `And` uniquement.
- `findByAgeGreaterThanEqual` ⇒ `GREATER_THAN_EQUAL`, pas `GREATER_THAN` — la
  résolution par `endsWith` sur la part entière suffit, sans règle de plus longue
  correspondance.
- `findByNameNotNull` ⇒ `IS_NOT_NULL`, pas `IS_NULL` : l'ordre de `ALL` le garantit.
- `findByNameNotLike` ⇒ `NOT_LIKE`, pas `LIKE`.
- `findByNameNotIn` ⇒ `NOT_IN`, pas `IN`.
- `findByName` ⇒ `SIMPLE_PROPERTY` par défaut.
- `findDistinctTop5ByName` ⇒ `distinct = true`, `max_results = 5`.
- `findTopByName` ⇒ `max_results = 1`.
- `countDistinctByName` ⇒ `distinct = true`, aucun `max_results` possible.
- `findByNameContainingIgnoreCase` ⇒ `CONTAINING` + `ignore_case`, dans cet ordre.
- `findByNameAllIgnoreCaseAndAge` ⇒ retrait global avant découpage.
- `findByAgeBetween` ⇒ 2 paramètres.
- `findByNameOrderByAgeDesc` ⇒ un prédicat, un tri descendant.
- `findByNameOrderByAgeOrderByName` ⇒ erreur, double `OrderBy`.
- `findBy` ⇒ état `expect_property`, aucune proposition de méthode complète.

## 7. Filtrage par type

Seule partie non issue de Spring. Objectif : ne pas proposer `Containing` sur un
`Integer`, ni `Between` sur un `String`.

### Catégories

| Catégorie | Types Java |
|---|---|
| `string` | `String`, `char`, `Character` |
| `numeric` | `int`, `long`, `short`, `byte`, `float`, `double` et wrappers, `BigDecimal`, `BigInteger` |
| `temporal` | `LocalDate`, `LocalTime`, `LocalDateTime`, `Instant`, `ZonedDateTime`, `OffsetDateTime`, `Date`, `Timestamp`, `Year`, `YearMonth` |
| `boolean` | `boolean`, `Boolean` |
| `collection` | `List<…>`, `Set<…>`, `Collection<…>` |
| `unknown` | tout le reste : enum, entité liée, type personnalisé |

### Compatibilité

| Condition | Catégories acceptées |
|---|---|
| `Between`, `LessThan`, `LessThanEqual`, `GreaterThan`, `GreaterThanEqual` | `numeric`, `temporal` |
| `After`, `Before` | `temporal` |
| `Like`, `NotLike`, `StartingWith`, `EndingWith`, `Containing`, `NotContaining` | `string` |
| `IgnoreCase` | `string` — `JpaQueryCreator` exige explicitement une `String` |
| `True`, `False` | `boolean` |
| `IsEmpty`, `IsNotEmpty` | `collection` — `JpaQueryCreator` lève sinon *« IsEmpty / IsNotEmpty can only be used on collection properties »* |
| `In`, `NotIn` | toutes sauf `collection` |
| `IsNull`, `IsNotNull` | toutes — mais exclues si le type Java est un **primitif** (`int`, `long`, `boolean`, …), qui ne peut être `null` |
| `Is`, `Equals`, `Not` | toutes |

L'exclusion sur les primitifs se décide sur le **type Java exact**, non sur la
catégorie : `boolean` et `Boolean` partagent la catégorie `boolean` mais seul le
second accepte `IsNull`.

Catégorie `unknown` ⇒ jeu neutre : `Is`, `Equals`, `Not`, `IsNull`, `IsNotNull`,
`In`, `NotIn`.

Le filtrage ne masque **que** les propositions. Une chaîne déjà tapée avec un mot-clé
incompatible reste parsée, et l'incompatibilité est remontée dans `errors`.

## 8. Type de retour

`T` désigne l'entité. Règles évaluées dans l'ordre :

1. Catégorie `count` ⇒ `long`
2. Catégorie `exists` ⇒ `boolean`
3. Catégorie `delete` ⇒ `void` par défaut, `long` si l'option de `setup()`
   `delete_return_type = "long"` est activée
4. `max_results == 1` ⇒ `Optional<T>` — couvre `findFirstBy…`, `findTopBy…`, mais
   aussi la forme explicite `findTop1By…`
5. `max_results` supérieur à 1 ⇒ `List<T>`
6. Prédicat unique, sans `Or`, dont la condition est `SIMPLE_PROPERTY` — c'est-à-dire
   `Is`, `Equals`, ou l'absence de tout mot-clé — sur un champ annoté `@Id` ou
   `@Column(unique = true)` ⇒ `Optional<T>`
7. Sinon ⇒ `List<T>`

Justification de la restriction de `Optional<T>` — table officielle des types de
retour :

> `Optional<T>` — Expects the query method to return **one result at most**. If no
> result is found, `Optional.empty()` is returned. **More than one result triggers an
> `IncorrectResultSizeDataAccessException`.**

`Optional<T>` encode « au plus un », non « peut être absent » : l'absence est déjà
couverte par `List<T>`, qui renvoie une liste vide et jamais `null`. Émettre
`Optional<T>` pour un champ non unique produirait du code qui démarre puis échoue à
l'exécution dès la deuxième ligne correspondante. La forme correcte pour « ce nom peut
ne pas exister » est `Optional<T> findFirstByName(String name)`, couverte par la
règle 4.

## 9. `entity.lua`

### Résolution de l'entité

Le premier paramètre générique de `extends …Repository<T, ID>` est extrait **par
treesitter**, jamais par regex : `interface_declaration` → `super_interfaces` →
`generic_type` → premier `type_arguments`.

### Extraction des champs

`documentSymbol` ne remonte pas les annotations, or `@Id` et `@Column(unique = true)`
sont nécessaires au type de retour. Donc :

- **jdtls localise** : `workspace/symbol` sur le nom de `T` ⇒ URI du fichier source.
- **treesitter extrait** : le fichier est parsé pour en tirer, en une passe, les
  `field_declaration` avec nom, type et annotations.

Ce partage évite un aller-retour LSP supplémentaire et donne les annotations
gratuitement.

### Cache

Par entité, invalidé sur `BufWritePost` du fichier de l'entité.

## 10. `source.lua`

- `enabled()` : filetype `java`, buffer contenant une `interface_declaration` dont un
  `super_interfaces` correspond à `*Repository`.
- **Aucune proposition de `findBy` nu.** Une méthode complète n'est proposée qu'une
  fois au moins une propriété sélectionnée — le comportement inverse de Spring Tools
  est considéré comme du bruit par ses propres mainteneurs
  (`spring-projects/spring-tools#1014`).
- `insertText` : snippet LuaSnip, tabstops sur les noms de paramètres.
- Documentation de l'item : signature complète et snippet JPQL correspondant.

## 11. Tests

Runner maison `tests/run.lua`, exécuté par `luajit tests/run.lua`. `busted` n'est pas
installé sur la machine cible et l'outillage existant n'est pas modifié sans demande
explicite. `grammar.lua` et `parser.lua` étant purs, aucun lancement de Neovim n'est
requis.

`grammar_spec.lua` vérifie l'intégrité des données : unicité des alias, cohérence des
`args`, conservation de l'ordre de `ALL`.

`parser_spec.lua` couvre les cas du §6, écrits avant l'implémentation.

`entity.lua` et `source.lua` sont validés manuellement dans Neovim sur un projet
Spring Boot 3 / Maven à entités `jakarta.persistence`.

## 12. Ordre de réalisation

1. `grammar.lua` + `grammar_spec.lua`
2. `parser_spec.lua` (tests d'abord), puis `parser.lua`
3. `entity.lua`, vérifié à la main dans Neovim
4. `source.lua`
5. `README.md`, incluant le hors-périmètre du §3

## 13. Contraintes d'environnement

- Neovim 0.12.4 — utiliser `vim.uv` et non `vim.loop`, `vim.lsp.codelens.enable` et
  `vim.lsp.semantic_tokens.enable`.
- LSP Java : `nvim-jdtls`.
- Complétion : `blink.cmp`. Snippets : LuaSnip. Parser treesitter `java` installé.

## 14. Références

- `spring-data-commons` : `PartTree.java`, `Part.java`, `OrderBySource.java`
- `spring-data-jpa` : `JpaQueryCreator.java`
- Doc : « Query Creation », « Repository Query Keywords », « Repository Query Return Types »
- `spring-projects/spring-tools#1014`
