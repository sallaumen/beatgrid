# 04 — GraphQL Layer (Absinthe)

Patterns for a GraphQL API serving a first-party UI. Applies if you choose
GraphQL; the same "edge is a thin translator" principle applies to REST
([05](05-rest-api-layer.md)).

## Schema composition

Keep the root schema small — it `import_types` the type modules and
`import_fields` the query/mutation field objects. Split types, queries, and
mutations into per-domain modules so the schema scales without one giant file.

```elixir
# lib/my_app_web/graphql/schema.ex
defmodule MyAppWeb.GraphQL.Schema do
  use Absinthe.Schema

  import_types MyAppWeb.GraphQL.Types.OrderTypes
  import_types MyAppWeb.GraphQL.Types.CatalogTypes
  # ...

  query do
    import_fields :order_queries
    import_fields :catalog_queries
  end

  mutation do
    import_fields :order_mutations
  end
end
```

## Types — prefer result unions for mutations

Define an input object for the arguments and a **result union** of
`[<success>, :user_error]` for the payload, so expected/validation failures are
returned as *data* (not as top-level GraphQL errors). Absinthe 1.8 also supports
the `@oneOf` directive for "exactly one of" input shapes.

```elixir
# lib/my_app_web/graphql/types/order_types.ex
use Absinthe.Schema.Notation

input_object :place_order_input do
  field :product_id, non_null(:id)
  field :quantity, non_null(:integer)
end

union :place_order_result do
  types [:order, :user_error]
  resolve_type fn
    %MyApp.Orders.Order{}, _ -> :order
    %{errors: _}, _ -> :user_error
  end
end
```

## Resolvers are translators, not business logic

Resolvers are the **view layer** between internal data and the GraphQL contract.
They **don't** build Ecto queries, **don't** run business logic, and **don't**
authorize inside the context. They authorize at the boundary, call a context
function, and translate the result.

```elixir
# ❌ resolver embeds a query
def latest_event(parent, _args, _res) do
  {:ok, Repo.one(from e in Event, where: e.order_id == ^parent.id, select: max(e.inserted_at))}
end

# ✅ resolver delegates to the query module
def latest_event(parent, _args, _res) do
  {:ok, MyApp.Orders.OrderQuery.latest_event_at(parent)}
end
```

A full mutation resolver shows the standard `with` + authorize + context-call +
error-translate shape:

```elixir
# lib/my_app_web/graphql/resolvers/order_resolvers.ex
def place_order(user, %{input: input}, _res) do
  with :ok          <- MyApp.Authorization.authorize(user, :place_order, input),
       {:ok, order} <- MyApp.Orders.place_order(user.account, input, origin: user) do
    {:ok, order}
  else
    {:error, :forbidden} ->
      {:ok, errors_object(:forbidden, "You are not authorized to do that")}

    {:error, %Ecto.Changeset{} = changeset} ->
      {:ok, %{errors: MyApp.Changeset.graphql_errors(changeset)}}
  end
end
```

Wrap field resolvers in a small `with_user/1` helper that injects the current
user from context and short-circuits unauthenticated calls:

```elixir
def with_user(fun) do
  fn
    parent, args, %{context: %{current_user: user}} = res -> fun.(user, args, res)
    _parent, _args, _res -> {:error, :unauthenticated}
  end
end

# usage in a field:
field :place_order, non_null(:place_order_result) do
  arg :input, non_null(:place_order_input)
  resolve with_user(&OrderResolvers.place_order/3)
end
```

## Dataloader — the standard N+1 mitigation

Wire Dataloader into the schema `context/1` + `plugins/0`. Define sources in the
domain layer (each is a `Dataloader.Ecto` over the repo, optionally with a custom
query function).

```elixir
# schema.ex
def context(ctx) do
  loader =
    Dataloader.new()
    |> Dataloader.add_source(:default, MyApp.DataloaderSource.new())
  Map.put(ctx, :loader, loader)
end

def plugins, do: [Absinthe.Middleware.Dataloader] ++ Absinthe.Plugin.defaults()

# in a type:
field :line_items, list_of(:line_item), resolve: dataloader(:default)
```

Conventions:

- **Prefer the `:default` source** unless you genuinely need a custom one — a
  separate named source creates a parallel cache that doubles work.
- **Pass a primitive id** when the batch key is a schema module (an "id lookup"):
  `Dataloader.load(:default, User, parent.user_id)`. Pass the **parent struct**
  only for association traversals: `Dataloader.load(:default, :line_items, order)`.
- For a single load, a `load + on_load + get` helper keeps resolvers compact; but
  when a resolver needs several related pieces, issue all the `load` calls first
  and resolve them in **one** `on_load` so they batch in parallel (nesting the
  single-load helper serializes them).
- Avoid hand-rolled batch-loader functions — Dataloader exists for this.

## Middleware & pipeline

Keep custom field middleware minimal. The classic useful one is a **query-depth /
complexity limiter** registered globally:

```elixir
# schema.ex
def middleware(middleware, _field, _object) do
  if max = Application.get_env(:my_app, :graphql_max_depth) do
    [{MyAppWeb.GraphQL.Middleware.DepthLimiter, max} | middleware]
  else
    middleware
  end
end
```

Auth, authorization, and error formatting do **not** belong in middleware here —
auth in the `with_user/1` wrapper, authorization in resolvers, error formatting in
a result handler. (Custom Absinthe *phases* are the place for cross-cutting
logging/metrics on the document pipeline.)

## Endpoint, router, plug pipeline

Mount Absinthe behind a dedicated pipeline: fetch session → authenticate → build
the Absinthe context (copy `current_user`, request origin, bearer token into
`conn.private.absinthe.context`) → rate-limit. Capture the raw request body (via
a custom body reader) if you need to verify inbound webhook signatures elsewhere.

```elixir
# router
pipeline :graphql do
  plug :fetch_session
  plug MyAppWeb.Auth, scope: :user
  plug MyAppWeb.GraphQL.ContextPlug
  plug MyAppWeb.RateLimiter
end

scope "/graphql" do
  pipe_through [:graphql]
  forward "/", Absinthe.Plug, schema: MyAppWeb.GraphQL.Schema
end
```

## Errors → clients

Two complementary mechanisms:

- **Result-union "user_error" (preferred for mutations):** return
  `{:ok, %{errors: [%{code:, message:}]}}` so the union resolves to `:user_error`.
  Convert changesets with a helper that camelizes field names and tags a code.
- **Top-level GraphQL errors:** for the `{:error, _}` channel, a result handler
  formats changesets/atoms into Absinthe's error list.

```elixir
def graphql_errors(changeset) do
  changeset
  |> Ecto.Changeset.traverse_errors(fn {msg, opts} -> interpolate(msg, opts) end)
  |> Enum.flat_map(fn {field, msgs} ->
    Enum.map(msgs, &%{code: :unprocessable_entity, message: "#{camelize(field)} #{&1}"})
  end)
end
```

## Layer-specific conventions

- **A compile-time GraphQL sigil** (e.g. `~GQL`) for inline query strings in tests
  surfaces syntax errors at compile time instead of runtime.
- **Cursor pagination, with opt-in total count.** A `COUNT(*)` is a second query
  and often the slower one — make total-count opt-in. Append a stable tiebreaker
  (`{:asc, :id}`) to the order spec so pages don't overlap.
- **Cap bulk mutations** (e.g. ~20 inputs); have the client chunk beyond that.
- **"Scream tests" for enums/permissions:** when you add an enum value or grant a
  permission to a role, add a test that exhaustively asserts every value/role so a
  future unhandled branch fails loudly.
- **Don't expose fields the UI doesn't consume** — a GraphQL field is a contract;
  adding one is easy, removing one is a breaking change.

A complete vertical slice to imitate is the `place_order` example above: the input
object + result union (types), the field (mutations), and the resolver.
