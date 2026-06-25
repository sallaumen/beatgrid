# 05 — REST API Layer

Patterns for a versioned REST API aimed at external integrators (separate from any
first-party GraphQL surface). The same boundary rule applies: controllers
translate HTTP and delegate; query/business logic lives in the domain.

## Versioning

Version by **URL prefix** (`/v1`, `/v2`) and make each version its own pipeline +
controller/view family. Don't negotiate versions via headers — explicit prefixes
are easier to route, document, and reason about. Differences between versions
(ID shapes, auth model, pagination style) live in the pipeline and the
controller/view modules, not in branching inside shared code.

```elixir
# router
pipeline :api_v2 do
  plug :accepts, ["json"]
  plug MyApp.PublicApi.VersionPlug
  plug MyApp.PublicApi.AuthPlug          # -> assigns :api_client (or :account)
  plug MyApp.PublicApi.RateLimiter, version: :v2
end

scope "/v2", MyApp.PublicApi.V2 do
  pipe_through :api_v2
  resources "/orders", OrderController, only: [:index, :show, :create]
end
```

The router should also implement `Plug.ErrorHandler.handle_errors/2`: mask 5xx
exception bodies in production, normalize a JSON decode error to 422, and report
everything to your error tracker.

## Controller flow

The canonical action is a `with` chain: **cast input → authorize → call domain
context → preload what the view needs → render.** Unmatched `{:error, _}` falls
through to an `action_fallback` controller.

```elixir
# lib/my_app/public_api/v2/order_controller.ex
def create(conn, params) do
  account = conn.assigns.account

  with :ok          <- AccessPolicy.authorize(account, :create_order, account),
       {:ok, input} <- CreateOrderInput.new(params),
       {:ok, order} <- MyApp.Orders.place_order(account, input, origin: :public_api) do
    order = MyApp.Repo.preload(order, [:line_items])

    conn
    |> put_status(:created)
    |> render(:show, order: order)
  end
end
```

Four invariants visible here and throughout:

1. **Tenant scope comes from `conn.assigns`** (set by the auth plug), never from
   request params.
2. **Authorization is an explicit step** in the `with` chain.
3. **Domain calls pass an `origin`** (`:public_api`) so the audit trail records
   the source.
4. **Associations the view needs are preloaded in the controller**, not the view.

## Input validation — embedded schemas

Validate request params with Ecto **`embedded_schema` + changeset** modules
(`@primary_key false`). Expose a `new/1` that returns `{:ok, struct} | {:error,
changeset}` via `apply_action/2`, so the controller drops it straight into the
`with` chain.

```elixir
# lib/my_app/public_api/v2/create_order_input.ex
defmodule MyApp.PublicApi.V2.CreateOrderInput do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :product_id, :string
    field :quantity, :integer
    embeds_many :discounts, Discount
  end

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:new)
  end

  def changeset(input, attrs) do
    input
    |> cast(attrs, [:product_id, :quantity])
    |> cast_embed(:discounts)
    |> validate_required([:product_id, :quantity])
    |> validate_number(:quantity, greater_than: 0)
  end
end
```

A `to_internal/1` that maps public field names (often camelCase) to internal
domain attrs keeps the wire contract decoupled from your schema field names.

## Views — render only, raise on missing data

Use Phoenix 1.7+ **`*JSON` modules** (plain functions, not `Phoenix.View`).
Wrap payloads consistently (`%{data: ...}` / `%{data: [...], meta: %{...}}`).
Views **never query or preload** — and they should **raise loudly** if a required
association isn't loaded, converting a silent N+1 (or lazy-load) into an immediate
error the fallback handler turns into a 500.

```elixir
# lib/my_app/public_api/v2/order_json.ex
def show(%{order: order}), do: %{data: data(order)}
def index(%{orders: orders, page: page}), do: %{data: Enum.map(orders, &data/1), meta: page_meta(page)}

defp data(%Order{line_items: %Ecto.Association.NotLoaded{}}),
  do: raise(":line_items must be preloaded")

defp data(%Order{} = order) do
  %{
    id: order.id,
    status: order.status,
    line_items: Enum.map(order.line_items, &line_item/1)
  }
end
```

## Authentication & authorization

For an integrator API there's no end-user login — each consumer is an **API
client** (client id + secret, exchanged for a bearer token).

- **Token mint** (unprotected): `POST /v1/token` exchanges credentials for a
  token.
- **Per-request auth plug**: parse the bearer token, look it up, assign the
  tenant scope (`:account` / `:api_client`), `halt` on failure.

```elixir
def call(conn, _opts) do
  with [header] <- get_req_header(conn, "authorization"),
       {:ok, client} <- authenticate(header) do
    assign(conn, :api_client, client)
  else
    _ -> conn |> put_status(:forbidden) |> put_view(ErrorJSON) |> render(:error) |> halt()
  end
end
```

Authentication establishes the *scope*; per-resource **authorization** is a
separate `AccessPolicy.authorize(scope, action, resource)` call in each action. A
resource the caller can't see should return **403** (or a deliberate 404 to hide
existence) — pick one policy and apply it consistently.

## Error mapping — the fallback controller

An `action_fallback` module maps domain `{:error, _}` returns to HTTP status +
JSON. Keep it as a flat pattern-match table, and unwrap domain error structs into
their `.message`.

```elixir
# lib/my_app/public_api/v2/fallback_controller.ex
def call(conn, {:error, %Ecto.Changeset{} = cs}),
  do: conn |> put_status(:unprocessable_entity) |> put_view(ErrorJSON) |> render(:error, changeset: cs)

def call(conn, {:error, :not_found}),
  do: conn |> put_status(:not_found) |> put_view(ErrorJSON) |> render(:error, message: "Not found")

def call(conn, {:error, %MyApp.Orders.OrderError{} = e}),
  do: conn |> put_status(:unprocessable_entity) |> put_view(ErrorJSON) |> render(:error, message: e.message)
```

Two error layers total: this fallback (for domain `{:error, _}`) plus the
router's `handle_errors/2` (for uncaught exceptions, e.g. a raised missing-preload).

## Webhooks (outbound)

If you emit events to subscribers, build a small delivery subsystem:

- **Emit** one event per domain occurrence, rendering the payload with the **same
  view module** used by REST responses (so the webhook body and the API response
  share a contract). Persist an event record and enqueue one delivery job per
  subscription.
- **Deliver** with a job worker (rate-limited per subscriber) that POSTs the
  event and retries with backoff on non-2xx.
- **Sign payloads** with an HMAC over the raw body + a timestamp, and document the
  verification recipe for subscribers.

## Contract documentation

Treat the API spec as a first-class, merge-gated artifact. Keep an **OpenAPI**
spec + changelog alongside the code, and require any change to public behavior
(endpoints, fields, requiredness, enums, auth, error contract, webhook payloads)
to ship matching doc updates in the same change. Crucially: **never leak internal
implementation details** into customer-facing docs or API responses — no internal
module/table names, no internal acronyms, no infrastructure names, no
implementation jargon. Describe behavior from the outside.

**Patterns to imitate:** controller `with`-chain → `order_controller.ex`; input →
`create_order_input.ex` (`new/1` + `apply_action`); view + preload-raise →
`order_json.ex`; error mapping → `fallback_controller.ex`.
