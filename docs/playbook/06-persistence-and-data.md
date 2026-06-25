# 06 — Persistence & Data (Ecto)

PostgreSQL via Ecto, through a wrapped repo. This file covers the repo wrapper,
the Ecto conventions that govern every query and changeset, migration rules,
encryption at rest, versioning, and search indexing.

## Wrap the repo

Define the repo once and extend it with project-wide helpers, so common
operations (cursor pagination, debugging, audited writes) have one home and
callers don't reach for low-level Ecto inconsistently.

```elixir
# lib/my_app/repo.ex
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres

  # cursor pagination wrapper
  def paginate(queryable, opts), do: # ... Paginator.paginate(...)

  # audited writes: write + audit entry in one transaction
  def insert_with_audit(changeset, opts), do: # ...
  def update_with_audit(changeset, opts), do: # ...

  # debugging: print the term, generated SQL, params, and EXPLAIN ANALYZE
  def inspect_query(queryable), do: # ...
end
```

Configure it with sane defaults: `migration_lock: :pg_advisory_lock`,
`migration_timestamps: [type: :utc_datetime]`, and a custom Postgrex types module
if you use extensions.

## Ecto conventions (the rules an AI most often gets wrong)

**Transactions.** Use `Repo.transact/1` (Ecto 3.x). Return `{:error, reason}` from
a `with` clause to roll back — **don't call `Repo.rollback` inside `transact`**.
Prefer `with` chains over `Ecto.Multi` for linear flows (Multi is fine for
fan-out, but `transact` + `with` reads better for the common case).

```elixir
Repo.transact(fn ->
  with {:ok, order} <- fetch_order(id),
       {:ok, order} <- update_order(order, attrs) do
    {:ok, order}
  end
end)
```

**No external calls inside an open transaction.** HTTP to a third party happens
before opening or after committing — a network round-trip inside a transaction
holds locks for its full duration.

**Query modules return resolved results** (`Repo.all/one`), not `Ecto.Query`
structs. Resolvers/controllers call query functions; they don't build queries.

**`Ecto.Enum` over `:string` + `validate_inclusion`.** Use `{:array, Ecto.Enum}`
for multi-select inputs. One source of truth, type-safe, drops the parallel
validation.

**Pair every DB constraint with a changeset constraint helper**
(`assoc_constraint/3`, `unique_constraint/3`, `check_constraint/3`) so a violation
attaches to a field instead of raising a raw `Postgrex.Error`.

**Preload discipline:**

- `Repo.preload` is idempotent and bulk-batched — one query for an N-element list.
  Don't pre-check `assoc_loaded?` or loop; don't `Enum.map(&Repo.preload/1)`.
- Use `force: true` to refetch an already-loaded association.
- **Don't preload bloated associations just to enqueue a job** — pass IDs to the
  worker and let it preload only what it needs.
- When a function *requires* a preload, `raise ArgumentError` if it's missing
  rather than preloading defensively (a defensive preload is a redundant hot-path
  round-trip and hides caller bugs).

**Query anti-patterns to avoid:** `or_where`/`OR` clauses (restructure as separate
queries, a `UNION`, or a build-time `dynamic/2` fragment); `distinct: true`
alongside a sub-existence join (use an `exists()` subquery instead); shadowing the
`Ecto.Query.limit/2` macro with a local `limit` variable.

**Bulk operations:** `update_all` does **not** bump `updated_at` — set it
explicitly in `set:`. For a bare touch, `Repo.update(changeset, force: true)`.
`insert_all` with `:placeholders` cuts wire traffic when many rows share a value.

## Time & timestamps

Default to `:utc_datetime` for any column representing an absolute moment
(`inserted_at`, `updated_at`, `*_at`, sync timestamps). Reach for
`:naive_datetime` only when the column genuinely has no timezone meaning. Both map
to the same Postgres type, so this is a type-system honesty decision. Normalize
external timestamps before storing: `DateTime.from_iso8601/1` already returns UTC;
strftime-parsed naive datetimes need an explicit `to_datetime`. Stamp "now" with
`DateTime.truncate(DateTime.utc_now(), :second)` to match second-precision columns.

## Migrations

**Idempotent create/drop.** Use `create_if_not_exists` for `index/2` **and**
`unique_index/2` (and `constraint/3`), with `drop_if_exists` in `down/0`.
Migrations get re-run across environments and retried after partial failure — the
`_if_(not_)exists` forms make these no-ops instead of hard errors.

**UUID primary keys + `:utc_datetime` timestamps:**

```elixir
create table(:orders, primary_key: false) do
  add :id, :uuid, primary_key: true, null: false
  add :status, :string, null: false
  add :account_id, references(:accounts, type: :uuid), null: false
  timestamps(type: :utc_datetime)
end
```

**Concurrent indexes in their own migration**, with `@disable_ddl_transaction`,
so they don't lock a hot table:

```elixir
defmodule MyApp.Repo.Migrations.AddOrdersAccountStatusIndex do
  use Ecto.Migration
  @disable_ddl_transaction true

  def change do
    create_if_not_exists index(:orders, [:account_id, :status],
      name: :orders_account_id_status_index, concurrently: true)
  end
end
```

**Postgres enum types** via a small `create_type/2` helper; extend with `IF NOT
EXISTS`:

```elixir
execute("ALTER TYPE order_status ADD VALUE IF NOT EXISTS 'refunded'", "")
```

**Index sensitivity.** Before shipping a hot-path query, audit indexes. For a
`WHERE x = ? AND ORDER BY y` (or `MAX/MIN/COUNT/LIMIT 1`) pattern, a composite
index on `(x, y)` is required — a plain `(x)` index forces a scan. Treat any
tenant-scoped operational table used on list pages, search, or routing as
index-sensitive, and add the index in the **same change** as the query.

**Backfills** belong in streamed release tasks (no global transaction around a
hot-table sweep), not in migrations. Verify migrations against a fresh test DB
rather than resetting your dev DB.

## Encryption at rest

Use Cloak: a vault module + a custom Ecto type per encrypted field. Key the
cipher from an environment variable and **fail to boot in production if it's
unset**. Reuse the same key to seed an HMAC for blind-index/lookup hashing.

```elixir
# vault
defmodule MyApp.Vault do
  use Cloak.Vault, otp_app: :my_app
end

# custom type
defmodule MyApp.Encrypted.Binary do
  use Cloak.Ecto.Binary, vault: MyApp.Vault
end

# in a schema — and keep the plaintext out of Inspect
@derive {Inspect, except: [:account_number]}
field :account_number, MyApp.Encrypted.Binary
```

## Versioning / audit

Common, composable mechanisms (see [03](03-domain-layer.md) for usage):

| Mechanism | Shape | Use |
|---|---|---|
| Action timeline | append a row per user action | Human-readable history, often search-synced |
| Generic diff-audit | protocol the schema derives; records only changed fields | Append-only, low-ceremony audit |
| Row versions | PaperTrail-style, written in the same transaction | Full before/after history |

In tests, assert on the audit/version rows, **never** on log text.

## Search indexing

Don't index synchronously in the request path. **Publish a sync event** (entity
type + id + action) to a broker, and let a streaming pipeline batch and bulk-index
into Elasticsearch/OpenSearch (Snap). This decouples write latency from index
latency and gives you back-pressure and retries for free. See
[07-jobs-and-messaging.md](07-jobs-and-messaging.md).

## Caching, locks, rate-limiting

Use Redis (Redix) for cross-node concerns: a distributed lock, a shared cache, a
rate limiter (`INCR` + `EXPIRE NX`). For node-local caches prefer ETS or
`:persistent_term`. Namespace cache keys per test process for isolation.

**Patterns to imitate:** the repo wrapper (`repo.ex`); the three migration
examples above; the Cloak vault + custom type; the publish-then-index search flow.
