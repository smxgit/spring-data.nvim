# spring-data.nvim

Spring Data JPA derived query method completion for Neovim, the way IntelliJ IDEA
does it.

Type `findByNameCont` in an interface extending `JpaRepository<UserEntity, Integer>`,
the plugin offers `Containing`, and inserts:

```java
List<UserEntity> findByNameContaining(String name);
```

## How it works

The grammar isn't transcribed from the documentation but from Spring Data's own
code — `PartTree.java`, `Part.java` and `OrderBySource.java` on the
`spring-data-commons` side, `JpaQueryCreator.java` on the `spring-data-jpa` side.
The documentation's keyword table belongs to `commons`, shared across every store,
and lists keywords JPA rejects at startup.

String splitting strictly follows Spring's algorithm: a keyword only splits if it's
followed by an uppercase letter. That's what keeps `findByAndrewAge` from being
split on `And`. The entity's field list is used to validate and to suggest, never to
arbitrate a split — the plugin therefore interprets the string exactly as Spring
will interpret it at runtime.

## Installation

Prerequisites: nvim-jdtls attached to the Java buffer, blink.cmp as the completion
engine, the `java` treesitter parser installed.

### With `vim.pack` (Neovim ≥ 0.12)

```lua
vim.pack.add({
  { src = "https://github.com/smxgit/spring-data.nvim" },
})

require("spring-data").setup({})
```

### With lazy.nvim / LazyVim

```lua
{
  "smxgit/spring-data.nvim",
  main = "spring-data",
  ft = "java",
  opts = {},
}
```

`opts = {}` is enough: lazy.nvim automatically calls
`require("spring-data").setup(opts)`. `main` is spelled out explicitly to remove
any ambiguity about the module name — lazy.nvim would correctly infer it from the
repo name (`spring-data.nvim` → `spring-data`), but there's no need to rely on
that.

### Local development

To work on the plugin itself, without going through a package manager:

```lua
vim.opt.rtp:prepend("/path/to/spring-data.nvim")
require("spring-data").setup({})
```

### Declaring the blink.cmp source

Whichever installation method you use, the source must be added to blink.cmp's
configuration:

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

None. `setup{}` takes an empty table and exists to install the autocommands.

Where Spring leaves the return type open, both candidates are offered in the
completion menu rather than fixed in configuration — see below.

## Return type

| Case | Type |
|---|---|
| `countBy…` | `long` |
| `existsBy…` | `boolean` |
| `deleteBy…` / `removeBy…` | `void` **and** `long`, both offered |
| `streamBy…` | the deduced type **and** `Stream<T>`, both offered |
| `findFirstBy…` / `findTopBy…` / `findTop1By…` | `Optional<T>` |
| `findTop5By…` | `List<T>` |
| Single predicate, no `Or`, equality on an `@Id` or `@Column(unique = true)` field | `Optional<T>` |
| Every other case | `List<T>` |

### When the choice is yours

Two shapes leave a genuine choice open, and Spring settles neither: a delete may
return `void` or the delete count, and a `streamBy…` may return a collection or
a `Stream<T>`. Both candidates are offered side by side:

```
󰊕 streamByAgeGreaterThan    List<UserEntity>
󰊕 streamByAgeGreaterThan    Stream<UserEntity>
```

They share the same label; only the inserted signature and the type shown beside
it differ. The deduced type comes first, since it is what the method's own shape
says.

This is deliberately not a setting. The decision belongs to the call site, not
to the project: the same repository legitimately wants a `Stream` in one method,
consumed inside a transaction, and a plain `List` in the next.

### `streamBy` and `Stream<T>`

`stream…By` does not by itself mean `Stream<T>`. The appendix of query subject
keywords groups it with `find…By`, `read…By`, `get…By`, `query…By` and
`search…By` as one *"general query method"*, `PartTree`'s `QUERY_PATTERN`
accepts the six interchangeably, and the documentation's own streaming example
is spelled `readAllByFirstnameNotNull()`. The keyword signals the intent without
imposing the type — which is why both are offered and neither is assumed.

Picking `Stream<T>` comes with obligations the plugin can't write for you:

```java
@Transactional
public void process() {
    try (Stream<UserEntity> users = repository.streamByAgeGreaterThan(18)) {
        users.forEach(…);
    }
}
```

Without a surrounding transaction Spring throws
`InvalidDataAccessApiUsageException: You're trying to execute a streaming query
method without a surrounding transaction…`, and without the try-with-resources
the underlying `ResultSet` leaks.

Only `streamBy…` gets that second candidate; the five other query keywords keep
returning the deduced type alone.

`Optional<T>` is deliberately reserved for queries whose maximum cardinality is
guaranteed to be one. The Spring documentation is explicit: *"Expects the query
method to return one result at most. More than one result triggers an
`IncorrectResultSizeDataAccessException`."* The "no result" case is already covered
by `List<T>`, which returns an empty list and never `null`. Emitting `Optional<T>`
for a non-unique field would produce code that starts fine and then fails as soon
as a second matching row exists.

## Diagnostics

```vim
:checkhealth spring-data
```

Completion degrades silently when the entity's field list can't be established:
no property and no condition are offered, only `And` / `Or` / `OrderBy`. That
output is indistinguishable from a genuine parse, so the health check walks the
same path `entity.fields` walks and reports which layer gave up — treesitter
parser, `jdtls` client, `workspace/symbol` lookup, entity buffer, class
declaration, extracted fields.

It reads **loaded buffers**, not the current window: `:checkhealth` opens its
own buffer, so keep the repository you want to diagnose open somewhere and run
the check from anywhere.

## Entity resolution

`workspace/symbol` matches on the simple name alone and answers everything on
the classpath. Querying `Document` on a Spring project returns dozens of
results, and the first one whose name matches exactly may well be
`BootstrapConfigFileApplicationListener$Document`, a nested class inside a
Spring Cloud jar. jdtls decompiles it, treesitter parses it, and completion
ends up offering the fields of a class the user never wrote.

Java's own resolution rules break the tie: an unqualified type name is either
imported explicitly, or declared in the same package, or covered by a wildcard
import. The repository's file therefore says where its entity lives, and
candidate packages are tried in that order.

The file path is the discriminator. Maven and Gradle both require a source file
to sit in the directory matching its package, so a real `com.example.Document`
can only live in `com/example/Document.java`. That single check rejects
homonyms from other packages, nested classes — whose file is named after the
outer class — and anything coming from a jar.

`jdt://` documents are never accepted, even when nothing else matches. An
entity shipped only as a compiled artifact is therefore not supported, which
buys the guarantee that every suggested field is one you actually declared.

## Inheritance

The entity's inheritance chain is walked upwards: a field declared in a
`@MappedSuperclass` parent — `id`, audit timestamps, a version column — is
suggested and validated like any other.

Only ancestors annotated `@MappedSuperclass` or `@Entity` contribute their
fields. The Jakarta Persistence specification excludes the state of a
superclass that is neither: such a class is plain object-model infrastructure,
and offering its fields would suggest query methods Spring rejects at startup.
A non-annotated class in the middle of the chain is still walked *through* —
`Entity → non-entity → MappedSuperclass` is legal — only its own fields are
dropped.

A field redeclared in a subclass shadows the inherited one, with the
subclass's type, as in Java.

When an ancestor can't be reached — a parent living in a jar such as
`AbstractPersistable`, or jdtls still indexing — the fields gathered so far are
still used to suggest properties, but no full signature is offered and nothing
is cached, so the next keystroke retries.

## Out of scope

Deliberately absent from this version:

- **Nested properties** (`findByAddress_ZipCode`) — requires recursive resolution
  of related entities, for a marginal use case.
- **Projections** and custom return types.
- **`Streamable`**, Vavr types.
- **`Pageable` / `Sort` parameters**, `Page` / `Slice` / `Window` return types.
- **`Near` / `Within`** — in JPA these are vector search keywords, not geospatial
  ones; they require a `Vector` field and a `Score` or `Range<Score>` parameter.
  Geospatial `findByLocationNear(Point, Distance)` belongs to Spring Data MongoDB.

Never offered, because they make the application fail to start:

- **`Regex` / `Matches` / `MatchesRegex`** and **`Exists` as a condition** —
  present in the documentation's table, inherited from `spring-data-commons`, but
  absent from `JpaQueryCreator`'s `switch`, which then raises
  `IllegalArgumentException: Unsupported keyword`.

## Tests

Two suites, kept apart on purpose.

```bash
luajit tests/run.lua              # pure, no Neovim
nvim --headless -l tests/run_nvim.lua   # treesitter over Java fixtures
```

`grammar.lua` and `parser.lua` never reference `vim`: the first suite runs
without Neovim. Neither does `source.lua`, outside the bodies of `enabled` and
`get_completions`, so its pure functions — current prefix, inserted-text
composition, snippet, option merging — are covered by the same suite. These
references to `vim` must never surface at module-load time.

The second suite covers `entity.lua`, which needs a real Neovim to run
treesitter over the Java fixtures in `tests/fixtures/`. It needs **no jdtls**:
the inheritance walk takes its class resolver as a parameter — jdtls in
production, a fixture map in the tests — so field extraction, the
`@MappedSuperclass` filtering and the shadowing rules are all exercised without
a language server.

What no suite covers, and is verified by hand in a Spring Boot project: the
jdtls resolver itself (`workspace/symbol` and buffer loading), the blink.cmp
plumbing in `source.lua`, and `health.lua`.
