# 03 — Domain Layer

The domain core holds business rules, state transitions, validation, persistence
orchestration, and audit. This file details each leg of the triad and the
cross-cutting patterns that live with it.

## (a) Context module — public API, mutations, delegation

The context module is the front door of a bounded context. It `defdelegate`s
reads to the query module and defines mutations inline. A mutation follows a
consistent shape: accept an explicit `origin`, build a named changeset, write via
the repo, `case` on the result, then record the audit/side effects.

```elixir
# lib/my_app/orders.ex
defmodule MyApp.Orders do
  alias MyApp.{AuditTrail, Repo}
  alias MyApp.Orders.{Order, OrderQuery}

  defdelegate get_order_by(opts), to: OrderQuery
  defdelegate fetch_order_by(opts), to: OrderQuery
  defdelegate list_orders_by(opts), to: OrderQuery

  @spec mark_as_paid(Order.t(), keyword()) :: {:ok, Order.t()} | {:error, term()}
  def mark_as_paid(%Order{} = order, opts) do
    origin = Keyword.fetch!(opts, :origin)

    order
    |> Order.mark_as_paid_changeset(%{paid_at: DateTime.utc_now(:second)})
    |> Repo.update()
    |> case do
      {:ok, order} ->
        AuditTrail.track(origin, order, :marked_as_paid)
        {:ok, order}

      error ->
        error
    end
  end
end
```

Multi-step mutations compose with `with` inside a transaction, and run side
effects (broadcasts, job enqueues, notifications) **after** the writes commit:

```elixir
def cancel_order(%Order{} = order, attrs, opts) do
  Repo.transact(fn ->
    with {:ok, order}  <- update_order(order, attrs, opts),
         {:ok, _items} <- release_reserved_stock(order) do
      broadcast_order_updated(order)
      MyApp.Notifications.OrderCancelledWorker.enqueue(order.id)
      {:ok, order}
    else
      {:error, %OrderError{} = error} -> {:error, error}
      {:error, reason} ->
        {:error, %OrderError{code: :cancel_failed, message: "Order could not be cancelled",
                             details: reason}}
    end
  end)
end
```

This obeys the persistence rules (see [06](06-persistence-and-data.md)): use
`Repo.transact/1` (compose with `with`, return `{:error, _}` to roll back — don't
call `Repo.rollback`), keep external calls and side effects *outside* the
transaction, and prefer `with` chains over `Ecto.Multi` for linear flows.

## (b) Ecto schema — structure + changesets

Schemas declare structure, type fields with `Ecto.Enum`, use UUID v7 primary
keys, default timestamps to `:utc_datetime`, and declare redaction/encryption
next to the field.

```elixir
# lib/my_app/billing/payment_method.ex
defmodule MyApp.Billing.PaymentMethod do
  use Ecto.Schema
  import Ecto.Changeset

  @redacted [:account_number, :routing_number]
  @derive {Inspect, except: @redacted}                  # keep secrets out of logs/inspect

  @primary_key {:id, Ecto.UUID, autogenerate: true}     # or a UUID v7 lib
  @timestamps_opts [type: :utc_datetime]

  schema "payment_methods" do
    field :kind, Ecto.Enum, values: [:ach, :card], default: :ach
    field :status, Ecto.Enum, values: [:active, :disabled], default: :active
    field :account_number, MyApp.Encrypted.Binary       # encrypted at rest (Cloak)
    field :routing_number, MyApp.Encrypted.Binary
    field :account_number_mask, :string

    belongs_to :account, MyApp.Accounts.Account
    timestamps()
  end

  def changeset(payment_method, attrs) do
    payment_method
    |> cast(attrs, [:kind, :status, :account_number, :routing_number, :account_id])
    |> validate_required([:account_id, :account_number, :routing_number])
    |> validate_routing_number()
    |> derive_account_number_mask()
    |> assoc_constraint(:account)
  end
end
```

Two practices worth copying:

- **`cast/3` then a pipeline of small private validators** (`validate_*`,
  `derive_*`) — each does one thing and is readable in sequence.
- **Multiple named changesets per transition** instead of one mega-changeset.
  Each layers a `put_change` + a domain rule on a shared base:

```elixir
def mark_as_paid_changeset(order, attrs) do
  order
  |> common_status_changeset(attrs)
  |> put_change(:status, :paid)
  |> validate_no_pending_refund()
end
```

For small input modules, `cast(attrs, __schema__(:fields) -- __schema__(:embeds))`
avoids hand-listing fields. Always pair a DB constraint with a changeset
constraint helper (`assoc_constraint`/`unique_constraint`/`check_constraint`) so a
violation attaches to a field instead of raising a raw `Postgrex.Error`.

## (c) Query module — all reads, composable

A `*Query` module owns every read for its aggregate. Two idioms work well
together.

**Small composable helpers** that take and return a queryable:

```elixir
# lib/my_app/orders/order_query.ex
import Ecto.Query

def with_status(queryable, status) do
  where(queryable, [o], o.status == ^status)
end

def placed(queryable) do
  where(queryable, [o], not is_nil(o.placed_at))
end
```

**A typed options keyword-list reduced into a query, then resolved.** Public
`*_by` functions seed a default scope, `Enum.reduce` the options through a
pattern-matched reducer, and call `Repo.*`. The options are exhaustively typed at
the top of the module, which keeps the context self-documenting.

```elixir
@type list_opt :: {:account_id, integer()} | {:status, atom()} | {:order_by, term()}
@spec list_orders_by([list_opt()]) :: [Order.t()]
def list_orders_by(opts \\ []) do
  opts
  |> Keyword.put_new(:order_by, desc: :inserted_at)
  |> Enum.reduce(default_scope(), &reduce_opt/2)
  |> Repo.all()
end

defp reduce_opt({:account_id, id}, q), do: with_account_id(q, id)
defp reduce_opt({:status, status}, q), do: with_status(q, status)
defp reduce_opt({:order_by, order}, q), do: order_by(q, ^order)
```

Follow the naming contract (see [09](09-conventions-and-code-style.md)): `get_*`
returns the value or `nil` (with a `!` variant that raises), `fetch_*` returns a
tagged tuple:

```elixir
@spec fetch_order_by([list_opt()]) :: {:ok, Order.t()} | {:error, :not_found}
def fetch_order_by(opts) do
  case get_order_by(opts) do
    nil -> {:error, :not_found}
    order -> {:ok, order}
  end
end
```

> **A deliberate guardrail:** for a "should be unique" lookup on a potentially
> huge table, `query |> limit(2) |> Repo.one()` keeps `Repo.one`'s "raise on >1
> row" guarantee without loading the whole table into memory. Don't "simplify" it
> away.

## Multi-tenancy & scoping (two layers)

Tenant-owned tables carry a tenant key (`account_id` / `organization_id`).
Scoping is layered:

**Layer A — direct tenant filtering** in the query module, with input
sanitation. An invalid id should collapse to an empty result, never leak:

```elixir
defp with_account_id(queryable, account_id) do
  case sanitize_id(account_id) do
    nil -> where(queryable, false)               # no rows
    id  -> where(queryable, [o], o.account_id == ^id)
  end
end
```

**Layer B — policy-based, per-user authorization scoping.** A `Scopes.scoped/2`
function dispatches on the schema in the query's `from` to a per-schema policy
that joins through membership and gates on role flags:

```elixir
# lib/my_app/authorization/scopes.ex
def scoped(%Ecto.Query{from: %{source: {_, schema}}} = q, %User{} = user) do
  Policy.scoped(schema, q, user)
end

# Policy.scoped/3 for Order — only rows the user may see
def scoped(Order, q, %{id: user_id}) do
  from o in q,
    join: m in Membership, on: m.account_id == o.account_id and m.user_id == ^user_id,
    where: m.role in [:owner, :admin, :member]
end

def scoped(_schema, q, _user), do: q                # safe default
```

Compose the two layers (plus any collection filters) in the context so the edge
just passes the current user and arguments.

## Origin & audit trail

Thread an **origin** — who or what triggered a change — from the edge into every
state-changing function, and record it.

```elixir
# lib/my_app/origin.ex
@type origin_type :: :system | :user | :admin | :public_api | :job
# the two-tuple distinguishes "admin acting for a user" (impersonation) from
# "a user acting on their own behalf"
@type origin :: User.t() | origin_type() | {:admin | :user, User.t()}
```

Pass it as an opt or last positional argument; default `:system` only for
machine-triggered work:

```elixir
origin = opts[:origin] || :system           # OK for cron/backfill
origin = Keyword.fetch!(opts, :origin)       # required when a real actor must be known
```

Common audit/versioning mechanisms (pick one or combine):

1. **An action timeline** — append a row per meaningful user action
   (`AuditTrail.track(origin, entity, :action, context)`), optionally synced to a
   search index for fast querying.
2. **A generic, append-only, diff-tracked audit** driven by a protocol the
   schema derives (`@derive {MyApp.Auditable, redacted_fields: [...]}`), recording
   only changed fields.
3. **Row-version history** (PaperTrail-style) written inside the same transaction
   as the change, so the version and the data commit atomically.

> **Hard deletes go through business functions, never raw SQL.** A bare
> `Repo.delete!` or `DELETE FROM` skips audit, downstream cleanup, and
> money/state-tied checks. Expose `hard_delete_*` functions on the context and
> walk each record through them.

## Errors as data — domain error structs

Fallible domain operations return `{:error, struct}` where the struct is a
`defexception` with a canonical `:code`, `:message`, `:details` shape (plus the
relevant entity when useful).

```elixir
# lib/my_app/orders/order_error.ex
defmodule MyApp.Orders.OrderError do
  defexception [:message, :code, :details, :order]

  @type t :: %__MODULE__{message: String.t(), code: atom(), details: any(), order: any()}
end
```

`:code` is the programmatic discriminator the edge matches on; `:message` is
human-readable; `:details` carries the debug payload. Fold a new error into the
closest existing struct rather than starting a parallel hierarchy. The error
philosophy in full is in [09-conventions-and-code-style.md](09-conventions-and-code-style.md).

## Small standard-library extensions

Keep a tiny, well-scoped `Ext.*` namespace for genuinely generic helpers that
extend the standard library — not a junk drawer for domain logic. Typical members:

| Module | Useful functions |
|---|---|
| `Ext.Enum` | `each_while/2`, `map_while/2` (iterate until first `{:error, _}`), `index_by/2`, `present?/1` |
| `Ext.String` | `presence/1`, `blank?/1`, `present?/1`, `mask/2` (PII masking) |
| `Ext.Map` | `maybe_put/3`, `deep_merge/2`, `deep_compact/1`, `indifferent_get/3` |
| `Ext.Keyword` | `maybe_put/3` |

Anything domain-specific belongs in a context, not in `Ext.*`. A "reach-for"
table is in [09](09-conventions-and-code-style.md).
