# 07 — Background Jobs, Messaging & Scheduling

Asynchronous work runs on three substrates: **Oban** (Postgres-backed jobs),
**Broadway** (streaming/event pipelines over a broker), and a **scheduler** (Oban
Cron and/or Quantum). Telemetry ties them together.

## Background jobs — Oban

Oban stores jobs in Postgres, so enqueue is transactional with your domain writes
and the job table is queryable and observable. Use **Oban Pro** when you need
workflows, chained/sequenced execution, or dynamic queues.

Configure queues centrally with per-queue concurrency limits. Useful advanced
limits: a `global_limit` (cluster-wide cap, optionally partitioned by an arg), a
`rate_limit` (e.g. respect a provider's quota), and `global_limit: 1` for a
cluster-exclusive queue.

### Worker conventions

- **`use Oban.Pro.Worker` (or `Oban.Worker`) with an args schema** so invalid
  jobs fail at enqueue time, not deep inside `process/1`.
- **Expose `enqueue/1` (and a `build/2`)** that accept either a struct or an id and
  call `Oban.insert/1`. **Store IDs in args, not structs** — let the job preload
  only what it needs (cheaper, and avoids stale embedded data).
- **Uniqueness:** `unique: [keys: [...], states: :incomplete]` (add `period:
  :infinity` for reactive/idle workers) to debounce duplicate enqueues.
- **`max_attempts: 1` for destructive/irreversible operations** (refunds, voids) —
  no automatic retries on side-effecting work that can't be safely repeated.
- **Bulk fan-out uses `Oban.insert_all/1`** (one transaction), never a loop of
  `Oban.insert/1`.
- **Set a correlation id and logger metadata** at the top of `process/1`.

```elixir
# lib/my_app/orders/recalculate_totals_worker.ex
defmodule MyApp.Orders.RecalculateTotalsWorker do
  use Oban.Pro.Worker,
    queue: :orders,
    max_attempts: 3,
    unique: [keys: [:order_id], states: :incomplete]

  args_schema do
    field :order_id, :string, required: true
    field :correlation_id, :string
  end

  def build(order_id, opts \\ []) do
    new(%{order_id: order_id, correlation_id: MyApp.Correlation.get()},
        schedule_in: opts[:debounce_seconds] || 5,
        replace: [scheduled: [:scheduled_at, :args]])
  end

  def enqueue(order_or_id, opts \\ []), do: order_or_id |> id() |> build(opts) |> Oban.insert()

  @impl true
  def process(%Oban.Job{args: %__MODULE__{order_id: id, correlation_id: cid}}) do
    MyApp.Correlation.put(cid)
    MyApp.Orders.recalculate_totals(id)
  end
end
```

**Advanced Oban Pro features worth knowing:** *Chain* (per-key serialized
execution — e.g. all jobs for one order run in order), *Workflow* (a DAG of
dependent jobs), and *Batch* (run a callback when a set of jobs completes).

Test workers with `perform_job/2`, `assert_enqueued/1`, `refute_enqueued/1` (see
[10](10-testing-and-tdd.md)).

## Streaming / events — Broadway

For high-throughput, broker-driven work (search indexing, event fan-out, ingest),
use **Broadway** over your broker (RabbitMQ/SQS/Kafka). Broadway gives you a
producer + processors + batchers with back-pressure, batching, and fault
tolerance.

Run pipelines under a supervisor with **`:rest_for_one`** so that if a shared
broker connection dies, the dependent producers/pipelines restart together. Build
options centrally (durable queues, `on_failure: :reject_and_requeue_once`, qos
prefetch tuned for back-pressure).

```elixir
# lib/my_app/search/sync_pipeline.ex
defmodule MyApp.Search.SyncPipeline do
  use Broadway
  alias Broadway.Message

  @impl true
  def handle_message(:default, %Message{data: data} = msg, _ctx) do
    case decode(data) do
      {:ok, %{entity: e, action: a} = payload} when e in @supported ->
        msg |> Message.update_data(fn _ -> payload end) |> Message.put_batcher(batcher_for(e, a))

      {:ok, _unsupported} -> Message.put_batcher(msg, :noop)   # ack and ignore
      {:error, reason} -> Message.failed(msg, reason)
    end
  end

  @impl true
  def handle_batch(:order_upsert, messages, _info, _ctx) do
    messages |> dedupe() |> MyApp.Search.Processors.Order.upsert_all()
    messages
  end
end
```

Patterns to note: route each message to a **per-entity batcher**; have a `:noop`
batcher that acks unsupported messages; **decode JSON with string keys** (only
converting known keys to atoms) to avoid atom-table exhaustion from untrusted
input; tune `prefetch_count` to roughly `batch_size * 2` for steady back-pressure.

## Scheduling

Two complementary approaches:

- **Oban Cron** — Postgres-backed recurring jobs. Best for the bulk of recurring
  work (cleanups, partition creation, periodic syncs). Recurrence and the job live
  in the same system you already observe.
- **Quantum** — an in-node scheduler. Pair it with **Highlander** so exactly one
  scheduler runs cluster-wide; a job can then publish a message to a broker for a
  Broadway pipeline to process (decoupling "when" from "what").

```elixir
# one scheduler instance across the cluster
children = [{Highlander, MyApp.Scheduler}]
```

Pick one as the primary path and be explicit about it; running two schedulers
without a clear split invites duplicate or missed runs.

## Telemetry / metrics

- **PromEx + Telemetry** for metrics, with plugins for Beam/Phoenix/Ecto/Oban/
  Broadway and your own custom plugins. Ship Grafana dashboards alongside.
- **A metrics poller** (DB gauges, queue depths) should run on **one node** —
  register it via Singleton so it doesn't multiply.
- Instrument **outbound calls** with `:telemetry` (duration + metadata) so you can
  alert on third-party latency/error rates.

## Observability conventions

- **Pass metadata as the 2nd `Logger` argument, not interpolated into the
  message:** `Logger.info("order placed", order_id: id)`. This keeps messages
  searchable and metadata structured.
- **Call `Logger.*` inline** at the site of interest — don't wrap it in a helper
  (you lose the line/module metadata).
- **Never end a function with a `Logger.*` call** — move it to the second-to-last
  expression or use `tap/2` (don't rely on Logger's return value).
- **Set `Logger.metadata/1` once per worker/process**; keys attach automatically
  thereafter.
- **No `Process.put/get` for request-scoped state** — async tasks run on other
  processes and the value vanishes. Use `conn.assigns` / the resolution context /
  job args.
- **Telemetry metric *labels* must be low-cardinality.** Never use a tenant id /
  entity id as a metric label (it explodes the time-series count); carry those as
  log metadata or trace attributes instead.
- **Thread a correlation id** across logs, jobs, and outbound calls so a single
  request is traceable end to end.

**Patterns to imitate:** the worker (`recalculate_totals_worker.ex`); the Broadway
pipeline (`sync_pipeline.ex`); the Highlander-wrapped scheduler.
