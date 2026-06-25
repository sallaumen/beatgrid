# 09 — Conventions & Code Style

Idiomatic Elixir conventions that make a codebase consistent and reviewable. These
are opinionated defaults; adopt them wholesale into a new project's style guide
(and into an AI assistant's system prompt) to get uniform code.

## Module organization

Order declarations consistently: `use` → `require` → `alias` → macros → guards →
`defdelegate` → public functions → private functions. Aliases are alphabetical,
full-path, at the top of the module (never inside a function body). Resolve alias
collisions with `as:`. Don't partial-alias and chain through it; don't alias
single-segment modules.

```elixir
defmodule MyApp.Orders do
  use SomeBehaviour
  require Logger
  alias MyApp.Orders.{Order, OrderQuery}

  defdelegate get_order_by(opts), to: OrderQuery

  def place_order(account, attrs, opts), do: # ...
  defp validate(attrs), do: # ...
end
```

Naming discipline: avoid generic catch-all modules (`Helpers`, `Util`, `Data`,
`Manager`); put cross-cutting code under the context it belongs to; don't invent a
third name for a concept that already has one.

## Function naming (a semantic contract)

| Prefix | Returns |
|---|---|
| `get_*` | the result or `nil` |
| `fetch_*` | `{:ok, result}` or `{:error, reason}` |
| `check_*` | preflight validation → `{:ok, value}` or `{:error, reason}` |
| `*?` | boolean |
| `foo!` | **discouraged** — if you add a bang, also expose the non-bang `{:ok,_}/{:error,_}` form |

Same operation + one extra argument → same name, higher arity (don't invent a new
name). Keyword `opts` default to `\\ []`, not `\\ %{}`.

## Errors as data

Fallible operations return `{:ok, _}` / `{:error, _}`. **Avoid raising for control
flow** — reserve raises for genuinely impossible cases. Compose with `with`; avoid
nested `case`.

```elixir
def process(id, attrs) do
  with {:ok, order} <- fetch_order(id),
       {:ok, order} <- check_ready(order),
       {:ok, order} <- update_order(order, attrs) do
    {:ok, order}
  end
end
```

**Generic error atoms are uninformative.** Don't return `:invalid` — return the
changeset, or a domain error struct, so the caller can render something useful:

```elixir
# ❌ {:error, :invalid}
# ✅ {:error, changeset}
# ✅ {:error, %MyApp.Orders.OrderError{code: :out_of_stock, message: "...", details: %{...}}}
```

Define `defexception` structs (`:code`, `:message`, `:details`) for domain errors
that bubble through a fallback handler. **Fail loud on bad *internal* inputs** —
let an unexpected shape crash with `FunctionClauseError` (pattern-match the head)
rather than adding a defensive branch that hides a bug. For a clearer message on a
contract violation, `raise ArgumentError`:

```elixir
def render(%Order{line_items: %Ecto.Association.NotLoaded{}}),
  do: raise(ArgumentError, "line_items must be preloaded before render/1")
```

Translate internal error atoms (e.g. `:stale`) into human-readable messages at
the API edge — consumers shouldn't see internal vocabulary.

## Pipes

Pipe only when chaining 2+ operations; start from a raw value; one `|>` per line.

```elixir
# ✅
order
|> Order.changeset(attrs)
|> Repo.update()

# ✅ single op — no pipe
Order.changeset(order, attrs)

# ❌ same-line pipe   |   ❌ pipe starting with a function call
```

## Pattern matching over conditionals

Branching on struct fields with `case`/`if` when a function head would do is a
smell. Use `match?/2` for *boolean* shape checks, not control flow. `if expr, do:
x` is fine without `else: nil`. Prefer `if not foo` over `unless` (soft-deprecated
in recent Elixir). Variable shadowing is fine — don't rename `order` → `order_2`
to silence a warning.

## Common mistakes to avoid

- **Never `String.to_atom/1` on user input** (atom-table memory leak). Use a safe
  lookup against existing atoms instead.
- **Never `hd(list)`** — pattern-match `[head | _] = list`.
- **Never `length(list) > 0`** — use `Enum.any?/1`. For "more than N":
  `Enum.count_until(list, N + 1) > N`.
- **Group large numbers** with `_`: `5_000`.
- **`Stream` inside multi-stage pipelines**, collapse with `Enum` at the end; plain
  `Enum.map` for an already-resolved list. `Enum.map_join/3` for joining.
- **Don't `import` then `defdelegate`** — `alias` and call directly. Prefer `alias`
  + `Module.const()` over `import Module, only: [...]` (import adds a recompilation
  edge).
- `get_in/1` over manual nil-safety chains.
- Macros only when there's a clear, justified need.

## Observability

- Metadata as the 2nd `Logger` arg, not interpolated into the message.
- Inline log calls (don't wrap `Logger.*` in a helper). Never end a function with a
  `Logger.*` call (use `tap/2`). `Logger.metadata/1` once per process.
- No `Process.put/get` for request state. Thread a correlation id rather than
  minting ad-hoc UUIDs. Telemetry metric labels must be low-cardinality.

## Audit / origin

Every state-changing function takes an `origin` (opt or last positional arg),
default `:system` only for machine-triggered work. Hard deletes go through
`hard_delete_*` business functions, never raw SQL or `Repo.delete!`. Backfill
scripts stream rows (no global transaction) and record versions.

## Documentation

Public functions get an `@spec` (enumerate opts as a keyword-list type).
Comments and docstrings explain **why**, not what. No line-number references in
comments (they go stale). Don't reference test modules from production code. Don't
write a "Used by …" section — grep for callers.

## Reach-for guide (prefer these over hand-rolling)

| Want to… | Use |
|---|---|
| short-circuit a map on `{:error, _}` | `Ext.Enum.map_while/2` |
| trim + nil-coerce empty strings | `Ext.String.presence/1` / `blank?/1` |
| atom-or-string key lookup | `Ext.Map.indifferent_get/2` |
| conditionally add a key | `Ext.Keyword.maybe_put/3` |
| parse a user-supplied integer | a sanitizing helper (don't `String.to_integer/1` — it raises) |
| safe deep access | `get_in/1` |
| compare decimals | `Decimal.eq?/2` — never `==` (`Decimal.new("0.0") != Decimal.new(0)`) |

## Data structures

Structs over maps when the shape is known. Keyword lists for options. Maps for
dynamic data. Prepend to lists (`[new | list]`), don't append.

## HEEx templates

Prefer the `:if`, `:for`, and `:let` attributes over `<%= if/for %>` blocks.

## Tooling gates (don't paper over findings)

If the linter, type checker, or security scanner flags something, fix the root
cause — don't disable the rule or delete the test to make CI green. A disable
comment is acceptable only when the rule is genuinely wrong for the case and you
can articulate why.

## Boundaries

**Always:** write tests for new functionality; format before committing;
`{:ok,_}/{:error,_}` for fallible ops; pattern-match over conditionals; `with` for
chains; idempotent + concurrent index migrations; update the API contract docs
when public behavior changes.

**Ask first (review/discuss):** new dependencies; new migrations; breaking API
schema changes; config changes; new background queues; external-integration
changes.

**Never:** commit secrets; `String.to_atom/1` on user input; raise for control
flow; skip tests for fixes/features; delete a failing test to green the build;
leak internal implementation details into customer-facing docs or responses.
