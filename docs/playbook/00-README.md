# Elixir / Phoenix Architecture & Quality Playbook

> A generic, reusable handbook of architecture, design, testing, and library
> patterns for building large, maintainable Elixir/Phoenix systems. Drop it into
> any Elixir project — or feed it to an AI coding assistant as ground-truth
> context — to align on the same battle-tested conventions.

This playbook is technology-specific but **domain-agnostic**. Every example uses
a fictional application (`MyApp` / `MyAppWeb`) with neutral domains (`Accounts`,
`Catalog`, `Orders`, `Billing`, `Notifications`). Adapt the names; keep the
shapes.

## How to use this

Read top to bottom once to absorb the model, then keep the per-topic files handy
as a reference. When using it with an AI assistant, paste the index plus the
file(s) relevant to the task.

| # | File | Topic |
|---|------|-------|
| 01 | [`01-overview-and-stack.md`](01-overview-and-stack.md) | The recommended modern stack, runtime/OTP topology, request lifecycle |
| 02 | [`02-architecture-and-layering.md`](02-architecture-and-layering.md) | Layered + hexagonal design, dependency rules, the context/schema/query triad |
| 03 | [`03-domain-layer.md`](03-domain-layer.md) | Bounded contexts, schemas, changesets, query modules, scoping, audit, errors |
| 04 | [`04-graphql-layer.md`](04-graphql-layer.md) | GraphQL with Absinthe — resolvers as translators, Dataloader, middleware |
| 05 | [`05-rest-api-layer.md`](05-rest-api-layer.md) | Versioned REST APIs — controllers, input validation, JSON views, fallbacks |
| 06 | [`06-persistence-and-data.md`](06-persistence-and-data.md) | Ecto patterns, the repo wrapper, migrations, encryption, versioning, search |
| 07 | [`07-jobs-and-messaging.md`](07-jobs-and-messaging.md) | Background jobs (Oban), streaming (Broadway), scheduling, telemetry |
| 08 | [`08-integrations.md`](08-integrations.md) | External services as ports & adapters; HTTP clients; webhooks; resilience |
| 09 | [`09-conventions-and-code-style.md`](09-conventions-and-code-style.md) | Naming, pipes, `with`, errors-as-data, observability, idiomatic Elixir |
| 10 | [`10-testing-and-tdd.md`](10-testing-and-tdd.md) | TDD loop, case templates, factories, the mocking decision matrix |
| 11 | [`11-libraries-and-tooling.md`](11-libraries-and-tooling.md) | Recommended libraries by purpose + quality gates (Credo/Dialyzer/etc.) |

## The five principles that explain everything else

1. **Layer strictly, depend inward.** Web/REST/worker edges translate and
   authorize, then delegate. The domain holds business logic. Adapters at the
   outer edge talk to the world. Edges never reach past the domain into the
   database. ([02](02-architecture-and-layering.md))

2. **Model the domain as bounded contexts, each a triad.** Every aggregate is a
   *context module* (public API + mutations), an *Ecto schema* (structure +
   changesets), and a *query module* (all reads). Reads are delegated to the
   query module; nothing else builds queries. ([03](03-domain-layer.md))

3. **Errors are data.** Fallible operations return `{:ok, _}` / `{:error, _}`.
   Domain errors are structs with `:code`, `:message`, `:details`. Raising is
   reserved for genuine contract violations. ([09](09-conventions-and-code-style.md))

4. **Talk to the outside world through ports.** Each external service is a
   behaviour (the port) + a real adapter + a config selector. Tests swap a mock
   built for the same behaviour, so tests never hit the network.
   ([08](08-integrations.md))

5. **Test first, mock at the boundary.** Write the failing test, make it pass in
   the domain, refactor. Mock external behaviours with `Mox`; everything else is
   real. ([10](10-testing-and-tdd.md))

## "Prefer the modern thing" (current as of mid-2026)

This playbook recommends the current-generation choice and notes the legacy one
it replaces. Verify exact versions on Hex before pinning — these move.

| Use | Instead of | Why |
|---|---|---|
| **Req** | HTTPoison / HTTPotion / Tesla | Batteries-included, testable via `Req.Test`, actively developed |
| **Phoenix JSON views** (1.7+ plain modules) | `Phoenix.View` | Simpler, explicit, no view-module indirection |
| **Dataloader** | hand-rolled batch loaders | Solves N+1 generically, integrates with Absinthe |
| **`Repo.transact/2`** (Ecto 3.x) | `Repo.transaction/1` + manual `rollback` | Composes with `{:ok,_}/{:error,_}` and `with` |
| **`Ecto.Enum`** | `:string` + `validate_inclusion` | Type-safe, single source of truth |
| **`Mox` + `Mimic`** | global mocking / ad-hoc test doubles | Concurrency-safe, behaviour-checked |
| **LiveView 1.2** | server-rendered + JS sprinkles | Real-time UI without a separate SPA |

Reference versions seen as current in mid-2026: Elixir 1.19.5 (1.20 introduces
gradual typing), Erlang/OTP 27+, Phoenix 1.8.x, LiveView 1.2.x, Ecto 3.13/3.14,
Absinthe 1.8, Oban 2.23 (+ Oban Pro), Req 0.5/0.6.
