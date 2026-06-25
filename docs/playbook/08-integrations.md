# 08 — External Integrations (Ports & Adapters)

Every external service (payment provider, SMS gateway, ERP, object store,
sanctions screener, …) is integrated the same way: a **behaviour** (port) + a
**real adapter** + a **config selector** + a **mock for tests**. Learn it once,
apply it everywhere. This is the part of the architecture that makes the system
testable and swappable.

## Two-layer organization

Keep each integration in its own top-level namespace, and separate the SDK-level
client from the domain that uses it:

- **`lib/<service>/`** — a self-contained client: the **port** (`<Service>` facade),
  the **adapter** (`<Service>.HTTP`), a **`Behaviour`**, an **`Error`** struct, and
  typed param/result structs.
- **`lib/my_app/<service>/`** (optional) — a **domain gateway** that speaks your
  domain's vocabulary and translates to the SDK port. Use it when the mapping is
  non-trivial.

## The port/adapter pattern

**(a) The behaviour = the port contract** — `@callback`s returning tagged tuples of
typed structs:

```elixir
# lib/payments/behaviour.ex
defmodule Payments.Behaviour do
  @callback authorize_charge(Payments.ChargeParams.t()) ::
              {:ok, Payments.Charge.t()} | {:error, Payments.Error.t()}
  @callback capture_charge(charge_id :: String.t()) ::
              {:ok, Payments.Charge.t()} | {:error, Payments.Error.t()}
end
```

**(b) The facade resolves the adapter at compile time and `defdelegate`s** every
callback. Resolve via `Application.compile_env!` so the choice is fixed at build
time:

```elixir
# lib/payments.ex
defmodule Payments do
  @behaviour Payments.Behaviour
  @adapter Application.compile_env!(:my_app, [Payments, :adapter])  # Payments.HTTP | PaymentsMock

  @impl true
  defdelegate authorize_charge(params), to: @adapter
  @impl true
  defdelegate capture_charge(charge_id), to: @adapter
end
```

**(c) The adapter implements the behaviour** and normalizes the wire response into
typed structs — never leaking the raw HTTP response past the port:

```elixir
# lib/payments/http.ex
defmodule Payments.HTTP do
  @behaviour Payments.Behaviour

  @impl true
  def authorize_charge(%Payments.ChargeParams{} = params) do
    case request(:post, "/charges", params) do
      {:ok, body} -> {:ok, Payments.Charge.from_map(body)}
      {:error, _} = error -> error
    end
  end
end
```

**(d) Selection is config-driven** — prod wires the real adapter, test wires a mock
built for the *same behaviour*:

```elixir
# config/config.exs
config :my_app, Payments, adapter: Payments.HTTP

# config/test.exs
config :my_app, Payments, adapter: PaymentsMock
```

```elixir
# test/support/mocks.ex
Mox.defmock(PaymentsMock, for: Payments.Behaviour)
```

This is the whole trick: **the domain depends on the port; the implementation is
a one-line config change; tests never hit the network.**

**Two-layer ports** for rich domains:
`MyApp.Billing` (domain) → `MyApp.Billing.Gateway` (domain port, speaks
`Subscription`/`Account`) → `Payments` (SDK port) → `Payments.HTTP` /
`PaymentsMock` (adapter). The gateway is itself a behaviour with its own mock, so
domain tests can stub the gateway without caring about the SDK.

## HTTP client choice

Prefer **Req** for new REST clients — it's batteries-included (JSON, retries,
redirects) and test-injectable. Use **Neuron** for GraphQL clients. Reach for a
SOAP library only when an upstream forces it. Avoid HTTPoison/Tesla in new code.

A representative Req adapter with idempotency, telemetry, 429 handling, and a
test-injection hook:

```elixir
defp request(method, path, params) do
  start = System.monotonic_time()
  result = Req.request([method: method, url: url(path), json: params] ++ req_opts())
  emit_telemetry(method, path, System.monotonic_time() - start)

  case result do
    {:ok, %Req.Response{status: s, body: body}} when s in 200..299 -> {:ok, body}

    {:ok, %Req.Response{status: 429, body: body}} ->
      {:error, %Payments.RateLimitError{retry_after: retry_after(body)}}

    {:ok, %Req.Response{status: s, body: body}} when s in 400..599 ->
      {:error, %Payments.Error{code: error_code(body), message: message(body), details: body}}

    {:error, %Req.TransportError{} = e} ->
      {:error, %Payments.Error{code: :network_error, message: Exception.message(e)}}
  end
end

defp req_opts, do: Application.get_env(:my_app, Payments.HTTP, [])  # test injects plug: {Req.Test, _}
```

## Error handling

Every integration defines its own `defexception`, and the adapter **wraps all
upstream failures into `{:error, %<Service>.Error{}}`**. Map upstream error codes
to atoms so callers can pattern-match without parsing strings:

```elixir
# lib/payments/error.ex
defmodule Payments.Error do
  defexception [:message, :code, :details]
  @codes %{"invalid_card" => :invalid_card, "insufficient_funds" => :insufficient_funds}
  def code_from(str), do: Map.get(@codes, str, :unknown)
end
```

A dedicated `RateLimitError` carrying `retry_after` lets workers reschedule
intelligently.

## Inbound webhooks (verifying signatures)

Verify inbound webhooks in a **Plug** that runs before the controller and `halt`s
on failure. Compute the signature over the **raw request body** (capture it with a
custom body reader, since parsers mutate it). Use `Plug.Crypto.secure_compare/2`
for constant-time comparison and reject stale timestamps.

```elixir
# lib/my_app_web/plugs/payments_webhook_verification.ex
def call(conn, _opts) do
  raw = conn.assigns.raw_body
  with [sig] <- get_req_header(conn, "x-signature"),
       true <- valid_signature?(sig, raw),
       true <- fresh_timestamp?(conn) do
    conn
  else
    _ -> conn |> send_resp(400, "") |> halt()
  end
end

defp valid_signature?(sig, raw) do
  expected = :crypto.mac(:hmac, :sha256, signing_secret(), raw) |> Base.encode16(case: :lower)
  Plug.Crypto.secure_compare(sig, expected)
end
```

(GraphQL clients sometimes verify with JWT/JWKs instead of HMAC — same idea: a
plug that authenticates the payload before the handler runs.)

## Resilience patterns

- **Idempotency keys** on every mutating outbound call, so a retry can't
  double-charge / double-create.
- **Targeted retries** — retry only on transient signals (429, 502/503/504,
  known-transient upstream error codes); never blindly retry a side-effecting call.
  Surface a 429's `retry_after` rather than hammering.
- **Rate limiting** to respect upstream quotas (Oban `rate_limit` queues for
  outbound jobs; a Redis limiter for sync paths).
- **Telemetry** around each call (duration + metadata) for latency/error alerting.
- **Timeouts** tuned per upstream (some ERPs need minutes).
- Don't over-engineer a circuit breaker unless you've measured the need —
  idempotency + targeted retries + rate limits + timeouts cover most cases.

## ERP / SOAP integrations (when you must)

For XML/SOAP upstreams: build requests with an XML builder, parse responses with a
streaming XML→map parser, and POST with Req (or a SOAP lib for WSDL). Be aware
some upstreams are **order-sensitive** about XML elements — keep the element order
explicit and well-commented. Wrap the whole thing behind the same behaviour/port
so the domain doesn't know it's talking SOAP.

## What to imitate

Port + adapter + error: `payments/{behaviour,http,error}.ex`. Config-driven
selection: `config/{config,test}.exs` + `test/support/mocks.ex`. Resilient Req
adapter: the `request/3` above. Inbound webhook verification: the verification
plug. Two-layer port: a domain `Gateway` behaviour over the SDK port.
