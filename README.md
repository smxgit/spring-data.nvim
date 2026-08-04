# spring-data.nvim

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
vim.opt.rtp:prepend("/chemin/vers/spring-data.nvim")
require("spring-data").setup({})
```

Puis déclarer la source dans blink.cmp :

```lua
sources = {
  default = { "lsp", "path", "snippets", "buffer", "spring-data" },
  providers = {
    ["spring-data"] = {
      name = "SpringData",
      module = "spring-data.source",
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

Ces options se déclarent dans `setup{}`. Elles peuvent aussi l'être sur le provider
blink, via sa clé `opts`, qui l'emporte alors sur `setup{}`.

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
Neovim. `source.lua` non plus en dehors du corps de `enabled` et `get_completions`,
si bien que ses fonctions pures — préfixe courant, composition du texte inséré,
snippet, fusion des options — sont couvertes par la même suite. Ces références à
`vim` ne doivent jamais remonter au niveau du chargement du module.

`entity.lua` et le reste de `source.lua` se vérifient à la main dans un projet Spring
Boot.
