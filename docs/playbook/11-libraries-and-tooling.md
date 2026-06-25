# 11 — Libraries & Tooling

A recommended, purpose-organized library set plus the quality gates that keep a
codebase healthy. Versions below were current in mid-2026 — **verify on Hex before
pinning**, and prefer the latest stable minor.

## Recommended libraries by purpose

### Web / API
- **phoenix** (~> 1.8) — endpoints, router, plugs, controllers.
- **phoenix_live_view** (~> 1.2) — real-time UIs; colocated CSS in HEEx.
- **absinthe** (~> 1.8) + **dataloader** — GraphQL with N+1 batching; `@oneOf`.
- **plug**, **plug_cowboy** (or Bandit), **corsica** (CORS), **remote_ip**,
  **plug_attack** (rate limiting).

### Persistence / data
- **ecto** + **ecto_sql** (~> 3.13) — over PostgreSQL (**postgrex**).
- **paginator** (cursor pagination), **scrivener_ecto** (page-number, if needed).
- **cloak_ecto** — field encryption at rest.
- **decimal** — money math (compare with `Decimal.eq?/2`, never `==`).
- **paper_trail** — row versioning (or a custom append-only audit).
- a UUID v7 library for primary keys.

### Jobs / messaging / scheduling
- **oban** (~> 2.23) — Postgres-backed jobs; **Oban Pro** for Workflows, Chains,
  dynamic queues, the Smart engine; **oban_web** for the dashboard.
- **broadway** + a broker producer (**broadway_rabbitmq** / SQS / Kafka) — streaming
  pipelines.
- **quantum** — in-node scheduler; **highlander** / **singleton** —
  cluster-wide singletons; **libcluster** — clustering.

### Search & cache
- **snap** — Elasticsearch/OpenSearch client.
- **redix** — Redis (cache, locks, rate limiting).

### HTTP clients (outbound)
- **req** (~> 0.5/0.6) — the default REST client (testable via `Req.Test`).
- **neuron** — GraphQL client.
- **finch** — the HTTP engine many clients build on.
- A SOAP library only when an upstream forces WSDL/SOAP.
- Avoid HTTPoison/Tesla in new code.

### Documents / files / parsing
- **csv** / **nimble_csv** (CSV), **elixlsx** (Excel), a PDF library, an XML
  builder + a streaming XML→map parser (SOAP/legacy XML).

### Email / i18n
- **swoosh** (delivery; `Swoosh.Adapters.Test` for assertions), **gettext**.

### Observability / ops
- **sentry** (errors), **prom_ex** + **telemetry** (+ metrics / metrics_statsd /
  poller), **opentelemetry** (tracing), **logger_json** (structured logs).

### Time
- **timex** + **tzdata** (or stdlib `Calendar`/`DateTime` where sufficient).

## Quality gates

Make `mix lint` (or equivalent) the single pre-commit gate. A good composition:

```
lint.deps  → mix deps.unlock --check-unused, mix hex.audit, mix deps.audit
lint.code  → mix format --check-formatted, mix credo --all --strict,
             mix dialyzer, mix sobelow --config
```

- **Formatter** (`mix format`, `.formatter.exs`) — non-negotiable before commit.
- **Credo** (`--all --strict`) for style/consistency; **credo_naming** for
  module/file naming. Don't disable a check to green CI — fix the cause.
- **Dialyzer** (via **dialyxir**) for type/spec checks; keep PLTs cached. Public
  functions get `@spec`s. (Elixir 1.20's gradual typing increasingly complements
  this.)
- **Sobelow** for Phoenix security static analysis; skip a finding only with a
  documented justification.
- **mix_audit** / **hex.audit** for dependency vulnerability + retirement checks.
- **excoveralls** for coverage.
- **junit_formatter** for CI-ingestable test output.

## Dev / test dependencies

**ex_machina** (factories), **mox** (behaviour mocks), **mimic** (concrete-module
mocks), **bypass** / **sham** (local HTTP server), **stream_data** (property
testing), **faker** (fake data), **floki** (HTML assertions), **benchee**
(benchmarks), **ex_doc** (docs).

## `mix` aliases worth defining

| Alias | Does |
|---|---|
| `mix lint` | the full pre-commit gate (deps + code) |
| `mix test.prepare` | drop/create/load/migrate the test DB (after migration changes) |
| `mix ecto.setup` / `ecto.reset` | create+migrate(+seed) / drop+setup |

## CI / release

- Run lint + tests on every PR; deploy via tags.
- **semantic-release** (or similar) to auto-version from **conventional commits**.
- Build/push a Docker image per commit to `main`.
- An AI/automated PR reviewer can complement (not replace) human review.

## Feature flags

If you use feature flags, require each flag declaration to carry a ticket/epic
reference (or a one-line context comment) so the future cleanup can find the
rollout context without archaeology:

```elixir
%FeatureFlag{
  name: "new_checkout_flow",
  default: false,
  description: "Rework of the checkout pipeline. See TICKET-1234."
}
```

## Adopting this in a new project (checklist)

1. Scaffold with the latest **Phoenix** generator; choose Ecto + PostgreSQL.
2. Wrap the repo (`MyApp.Repo` with the helpers from [06](06-persistence-and-data.md)).
3. Establish the **triad** convention and a first bounded context
   ([02](02-architecture-and-layering.md), [03](03-domain-layer.md)).
4. Add **Oban** + an example worker; add **Broadway** only when you have a broker
   workload ([07](07-jobs-and-messaging.md)).
5. Define your first **port/adapter** for any external service, with a Mox mock
   ([08](08-integrations.md)).
6. Set up **case templates**, **factories**, and the **mocking matrix**
   ([10](10-testing-and-tdd.md)).
7. Wire **`mix lint`** (format + credo + dialyzer + sobelow) into CI.
8. Add **Sentry** + **PromEx/Telemetry** and a correlation id from day one.

Adopt the conventions in [09](09-conventions-and-code-style.md) as the project's
style guide so every contributor (human or AI) writes in the same shape.
