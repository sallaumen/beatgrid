# 10 — Testing & TDD

A test-first workflow with ExUnit, ExMachina factories, and a four-technique
mocking strategy. This file is written so you (or an AI) can produce idiomatic
tests in any Elixir project.

## The TDD loop

1. **Write the failing test first**, at the smallest viable scope. Walk the ladder
   and stop at the first level that exercises your change:
   `mix test path/to/file_test.exs:LINE` → one file → a directory → a tag → full
   suite.
2. **Make it pass** in the domain layer.
3. **Refactor** under green.
4. **Inner-loop checks after each change:** `mix format`, `mix compile
   --warnings-as-errors`, the scoped `mix test`.
5. **Pre-commit, once:** the full lint suite + a directory/tag-scoped run. Reserve
   the full suite for cross-cutting changes (auth, factories, migrations, case
   templates).

Tag names aren't validated by ExUnit (`mix test --only typo` runs zero tests and
exits 0) — grep to confirm a tag exists before trusting a tag-scoped pass.

## Case templates

Provide a small set of `ExUnit.CaseTemplate`s so test files start with one `use`
that wires the sandbox, imports, and helpers.

```elixir
# test/support/data_case.ex — the workhorse for DB-touching tests
defmodule MyApp.DataCase do
  use ExUnit.CaseTemplate

  using opts do
    [
      if(Keyword.get(opts, :properties, false), do: quote(do: use ExUnitProperties)),
      if(Keyword.get(opts, :oban, false), do: quote(do: use Oban.Pro.Testing, repo: MyApp.Repo)),
      quote do
        import Ecto.Changeset
        import Ecto.Query
        import Mox
        import MyApp.Factory
        import MyApp.DataCase            # errors_on/1, reload/2, update!/2
      end
    ]
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Mox.verify_on_exit!(tags)
    :ok
  end
end
```

Header opts to support: `async: true` (private sandbox connection — the default
you want), `oban: true` (brings in `perform_job/2`, `assert_enqueued/1`),
`properties: true` (StreamData's `property` / `check all`). Mirror this with a
`ConnCase` for web/GraphQL tests (auth helpers, an in-process GraphQL runner) and
specialized cases for channels/components.

Bake small helpers into the case (or a shared module it imports): `errors_on/1`
(traverse changeset errors into a `%{field => [msg]}` map), `reload/2`, `update!/2`.

## Factories (ExMachina)

Use ExMachina with the Ecto adapter. The key idiom is the **`Map.pop_lazy`
optional-association pattern**: pop a possibly-supplied association, otherwise
lazily insert a default — so passing the assoc explicitly doesn't trigger a
redundant insert. Always end with `evaluate_lazy_attributes/1`.

```elixir
def order_factory(attrs) do
  {account, attrs} = Map.pop_lazy(attrs, :account, fn -> insert(:account) end)

  %MyApp.Orders.Order{
    account: account,
    status: :placed,
    reference: sequence(:reference, &"ORD-#{&1}")     # sequence for uniqueness
  }
  |> merge_attributes(attrs)
  |> evaluate_lazy_attributes()
end
```

Keep factory defaults minimal — every default cascades into other tests and
creates implicit coupling.

## The mocking decision matrix

Four complementary techniques. Choosing the right one is most of getting tests
right:

| Technique | When | How it's wired | In a test |
|---|---|---|---|
| **Mox** | A behaviour-based **port/adapter** (external service). The default at any integration boundary. | `Mox.defmock(XMock, for: X.Behaviour)`; wire it in `config/test.exs`. | `Mox.expect(XMock, :fun, fn … end)`; `verify_on_exit!`. |
| **Mimic** | Replacing a **concrete in-app module** (no behaviour), or stubbing one function while the rest runs for real; also stdlib `Date`/`DateTime`/`Req`. | `Mimic.copy(Mod)` globally in `test_helper.exs` or locally in `setup`. | `Mimic.stub/expect(Mod, :fun, fn … end)` (fully-qualified; no `use`). |
| **Req.Test** | HTTP stubbing for **Req-based** clients. | client config carries `plug: {Req.Test, ClientMod}`; point at a fake URL. | `Req.Test.stub(ClientMod, fn conn -> Req.Test.json(conn, …) end)`. |
| **Bypass / Sham** | A **real local HTTP server** when you want to assert raw request headers/body. | start a server in the test; point the client config at its port. | `Bypass.expect(bypass, "POST", "/path", fn conn -> … end)`. |

**Prefer `expect/3` over `stub/3`** — `stub` silently swallows unmet expectations;
`expect` fails the test if the call doesn't happen.

The load-bearing wiring is `config/test.exs`: production reads its collaborators
from config, and the test env points them at the mock.

```elixir
# config/test.exs
config :my_app, Payments, adapter: PaymentsMock
config :my_app, SmsClient, adapter: SmsClientMock
config :my_app, MyApp.Mailer, adapter: Swoosh.Adapters.Test   # assert with Swoosh.TestAssertions
```

## Representative tests

**(a) Domain unit test** — `describe` per function, pattern-matched assertions:

```elixir
defmodule MyApp.OrdersTest do
  use MyApp.DataCase, async: true, oban: true

  describe "place_order/3" do
    test "places an order with valid input" do
      account = insert(:account)
      assert {:ok, order} = Orders.place_order(account, %{product_id: "p1", quantity: 2}, origin: :system)
      assert order.status == :placed
    end

    test "returns a changeset error with invalid input" do
      account = insert(:account)
      assert {:error, changeset} = Orders.place_order(account, %{}, origin: :system)
      assert "can't be blank" in errors_on(changeset).product_id
    end
  end
end
```

**(b) Worker test** — `oban: true`, `perform_job/2`, `assert_enqueued/1`:

```elixir
use MyApp.DataCase, async: true, oban: true

test "recalculates totals and is idempotent" do
  order = insert(:order)
  assert :ok = perform_job(RecalculateTotalsWorker, %{order_id: order.id})
end

test "enqueue/1 inserts a job carrying the id" do
  order = insert(:order)
  assert {:ok, %Oban.Job{}} = RecalculateTotalsWorker.enqueue(order)
  assert_enqueued(worker: RecalculateTotalsWorker, args: %{order_id: order.id})
end
```

**(c) Integration test with a Mox port mock** (`expect/3` on the behaviour the
code resolves from config):

```elixir
use MyApp.DataCase, async: true

test "charges via the payment provider" do
  account = insert(:account)
  Mox.expect(PaymentsMock, :authorize_charge, fn _params ->
    {:ok, %Payments.Charge{id: "ch_1", status: :authorized}}
  end)

  assert {:ok, _} = MyApp.Billing.charge(account, 1000, origin: :system)
end
```

**(d) Property test** (StreamData):

```elixir
use MyApp.DataCase, async: true, properties: true

property "round-trips through the encoder" do
  check all term <- term_generator() do
    assert term == decode(encode(term))
  end
end
```

Property tests shine for parsers, encoders, and any input-shape-bound code — they
explore the space far better than hand-written cases.

## In-test conventions

- Test module name mirrors the module under test; `describe` per public function;
  private helpers at the **end** of the module.
- **Don't re-import** what the case template already imports.
- **No dead setup** — delete an unused binding; don't hide it behind `_name =
  insert(...)`. If a row is load-bearing for a side effect (FK, scope filter), use
  `_ = insert(...)` *with a comment* saying why.
- **Pattern-match over equality** (`assert %{key: v} = result` gives a far better
  failure message than `assert result.key == v`).
- **`reload/2`** over re-fetching with `Repo.get`. **`update!/2`** over hand-rolled
  `change |> Repo.update!`.
- **Don't assert on:** log message text, rendered CSS classes, or response field
  ordering (unless ordering is the contract). Assert on behavior, returned values,
  and resulting DB/audit state.
- **"Scream tests"** for permission/enum allowlists: loop over every role/enum
  value and assert the invariant, so a future change that violates it fails loudly.
- Use **fixtures via a helper** (not hand-rolled `File.read!`), and
  `start_supervised` for stateful test processes.
- Locally, clamp parallelism (`mix test --max-cases N`) when the DB + external
  deps run on the same machine.

## `test_helper.exs`

Start ExUnit (with a CI-friendly formatter, e.g. JUnit XML), set the Ecto sandbox
to `:manual` (the shared-vs-private decision happens per-test in the case), and
register any global `Mimic.copy` for stdlib modules you stub frequently
(`Date`/`DateTime`/`Req`). Don't start heavy external deps (search/Redis) globally
— gate them on a tag.

## Quick guide for a new test

- DB-touching context function → `use MyApp.DataCase, async: true` (+ `oban: true`
  if it enqueues/performs jobs, `+ properties: true` for StreamData).
- GraphQL/REST edge → the matching `ConnCase`; drive GraphQL in-process.
- Calls an external service behind a `@behaviour` → **Mox** (`expect/3`).
- Overrides a concrete in-app module or stdlib time/Req → **Mimic**.
- Tests a raw HTTP client → **Req.Test** (Req) or **Bypass/Sham** (local server).
- Always: factories with `Map.pop_lazy` assocs, `reload/2`, `errors_on/1`,
  exact-map pattern-matched assertions.
