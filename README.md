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

| Option | Default | Description |
|---|---|---|
| `delete_return_type` | `"void"` | Return type of `deleteBy` / `removeBy` methods. `"long"` to return the number of rows deleted. |

These options are declared in `setup{}`. They can also be set on the blink provider,
via its `opts` key, which then wins over `setup{}`.

## Return type

| Case | Type |
|---|---|
| `countBy…` | `long` |
| `existsBy…` | `boolean` |
| `deleteBy…` / `removeBy…` | `void`, or `long` depending on the option |
| `findFirstBy…` / `findTopBy…` / `findTop1By…` | `Optional<T>` |
| `findTop5By…` | `List<T>` |
| Single predicate, no `Or`, equality on an `@Id` or `@Column(unique = true)` field | `Optional<T>` |
| Every other case | `List<T>` |

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
