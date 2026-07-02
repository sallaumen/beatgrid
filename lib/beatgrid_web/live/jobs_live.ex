defmodule BeatgridWeb.JobsLive do
  @moduledoc """
  Background-jobs visibility: a live table of recent Oban jobs across all queues,
  with their state, queue, a human-readable summary of what each job is doing,
  attempts, timing, the last error, and retry/cancel actions.
  """
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Jobs
  alias Beatgrid.Library.Tracks

  @refresh_ms 2_000
  @states ~w(available scheduled executing retryable completed discarded cancelled)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok, assign(socket, states: @states, expanded: MapSet.new())}
  end

  # URL-driven filters (`?state=failed&worker=DownloadWorker`) so the Painel can
  # deep-link straight to "the downloads that gave up" and the view survives
  # refresh/back. "failed" is a pseudo-state covering discarded + cancelled.
  @impl true
  def handle_params(params, _uri, socket) do
    filter = valid_state(params["state"])
    worker = valid_worker(params["worker"])

    {:noreply, socket |> assign(filter: filter, worker: worker) |> assign_jobs()}
  end

  defp valid_state(state) when state in @states or state == "failed", do: state
  defp valid_state(_state), do: nil

  defp valid_worker(worker) when is_binary(worker) do
    if Regex.match?(~r/^[A-Za-z]+$/, worker), do: worker
  end

  defp valid_worker(_worker), do: nil

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign_jobs(socket)}
  end

  @impl true
  def handle_event("retry", %{"id" => id}, socket) do
    Jobs.retry(String.to_integer(id))
    {:noreply, assign_jobs(socket)}
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    Jobs.cancel(String.to_integer(id))
    {:noreply, assign_jobs(socket)}
  end

  def handle_event("retry_all_failed", _params, socket) do
    count = Jobs.retry_failed(socket.assigns.worker)
    {:noreply, socket |> put_flash(:info, "#{count} job(s) re-enfileirado(s).") |> assign_jobs()}
  end

  def handle_event("clear_all_failed", _params, socket) do
    count = Jobs.clear_failed(socket.assigns.worker)
    {:noreply, socket |> put_flash(:info, "#{count} falha(s) limpa(s).") |> assign_jobs()}
  end

  def handle_event("toggle_details", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, expanded: expanded)}
  end

  defp assign_jobs(socket) do
    jobs = load(socket.assigns.filter, socket.assigns.worker)
    assign(socket, jobs: jobs, titles: track_titles(jobs))
  end

  defp load(filter, worker),
    do: Jobs.list_recent(limit: 100, states: filter_states(filter), worker: worker)

  defp filter_states(nil), do: nil
  defp filter_states("failed"), do: ["discarded", "cancelled"]
  defp filter_states(state), do: [state]

  # Resolve the track titles referenced by the visible jobs in one batched query,
  # so the summary reads "Asa Branca" instead of a bare UUID.
  defp track_titles(jobs) do
    case jobs |> Enum.flat_map(&job_track_ids/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        Tracks.list_by(ids: ids)
        |> Map.new(fn t -> {t.id, t.tag_title || t.filename} end)
    end
  end

  defp job_track_ids(%Oban.Job{worker: worker, args: args}) do
    case worker_name(worker) do
      "AnalyzeWorker" -> List.wrap(args["track_id"])
      "ResolveSongWorker" -> List.wrap(args["track_id"])
      "EnrichWorker" -> if(args["scope"] == "track", do: List.wrap(args["id"]), else: [])
      "RecommendWorker" -> if(args["scope"] == "track", do: List.wrap(args["track_id"]), else: [])
      _ -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:jobs} socket={@socket}>
      <header class="border-b border-white/6 bg-rail px-6 py-3">
        <h2 class="text-[22px] font-semibold">Jobs</h2>
        <p class="text-ink-muted text-body-sm">
          Tarefas em segundo plano (downloads, análise, IA, Soundcharts). Atualiza sozinho.
        </p>
      </header>

      <div class="mx-auto max-w-[1600px] px-6 py-6">
        <div class="flex flex-wrap items-center gap-1.5">
          <.link
            patch={jobs_path(nil, @worker)}
            class={["rounded-sm border px-2.5 py-1 text-[12px]", chip_class(@filter == nil)]}
          >
            Todas
          </.link>
          <.link
            patch={jobs_path("failed", @worker)}
            class={["rounded-sm border px-2.5 py-1 text-[12px]", chip_class(@filter == "failed")]}
          >
            Falhas
          </.link>
          <.link
            :for={s <- @states}
            patch={jobs_path(s, @worker)}
            class={["rounded-sm border px-2.5 py-1 text-[12px]", chip_class(@filter == s)]}
          >
            {state_label(s)}
          </.link>
          <.link
            :if={@worker}
            patch={jobs_path(@filter, nil)}
            class="rounded-sm border border-primary/40 bg-primary/10 px-2.5 py-1 text-[12px] text-primary"
            title="Remover o filtro de tarefa"
          >
            {worker_label("." <> @worker)} ✕
          </.link>
          <span class="text-ink-faint ml-auto font-mono text-caption">{length(@jobs)} tarefa(s)</span>
        </div>

        <div
          :if={@filter == "failed" and @jobs != []}
          class="mt-3 flex flex-wrap items-center gap-2 rounded-lg border border-coral/25 bg-coral/5 px-3 py-2"
        >
          <span class="text-body-sm text-ink-secondary">
            {length(@jobs)} falha(s) nesta lista — cada linha diz qual música/URL falhou e por quê.
          </span>
          <button
            phx-click="retry_all_failed"
            class="rounded-md bg-primary/15 px-2.5 py-1 text-[11px] font-semibold text-primary hover:bg-primary/25"
          >
            Re-tentar todas
          </button>
          <button
            phx-click="clear_all_failed"
            data-confirm="Limpar todas as falhas listadas? Elas somem do histórico (nenhum arquivo é tocado)."
            class="rounded-md bg-white/6 px-2.5 py-1 text-[11px] font-semibold text-ink-muted hover:bg-white/10"
          >
            Limpar todas
          </button>
        </div>

        <div class="mt-4 overflow-x-auto rounded-xl border border-white/6 bg-surface">
          <table class="w-full text-left text-body-sm">
            <thead>
              <tr class="text-ink-faint border-b border-white/6 text-[10px] uppercase tracking-wider">
                <th class="px-4 py-2.5 font-semibold">Estado</th>
                <th class="px-4 py-2.5 font-semibold">Tarefa</th>
                <th class="px-4 py-2.5 font-semibold">Fila</th>
                <th class="px-4 py-2.5 text-center font-semibold">Tentativas</th>
                <th class="px-4 py-2.5 font-semibold">Quando</th>
                <th class="px-4 py-2.5 text-right font-semibold">Ações</th>
              </tr>
            </thead>
            <tbody :for={j <- @jobs} class="border-b border-white/4 last:border-0">
              <tr class="hover:bg-white/[0.02]">
                <td class="whitespace-nowrap px-4 py-3 align-top">
                  <span class={[
                    "rounded-sm px-2 py-0.5 text-[10px] font-bold uppercase",
                    state_class(j.state)
                  ]}>
                    {state_label(j.state)}
                  </span>
                </td>
                <td class="px-4 py-3 align-top">
                  <div class="flex items-center gap-2">
                    <span class="text-body-sm font-medium">{worker_label(j.worker)}</span>
                    <span class="text-ink-faint rounded bg-white/6 px-1.5 py-0.5 font-mono text-[10px]">
                      {worker_name(j.worker)}
                    </span>
                  </div>
                  <p class="text-ink-muted mt-0.5 max-w-[680px] truncate font-mono text-caption">
                    {job_summary(j, @titles)}
                  </p>
                  <p :if={last_error(j)} class="text-coral mt-0.5 max-w-[680px] truncate text-caption">
                    {last_error(j)}
                  </p>
                </td>
                <td class="whitespace-nowrap px-4 py-3 align-top">
                  <span class="text-ink-muted rounded-sm bg-white/6 px-2 py-0.5 font-mono text-[11px]">
                    {j.queue}
                  </span>
                </td>
                <td class="text-ink-muted whitespace-nowrap px-4 py-3 text-center align-top font-mono text-[12px]">
                  {j.attempt}/{j.max_attempts}
                </td>
                <td class="text-ink-faint whitespace-nowrap px-4 py-3 align-top font-mono text-[12px]">
                  {ago(job_time(j))}
                </td>
                <td class="whitespace-nowrap px-4 py-3 text-right align-top">
                  <div class="flex items-center justify-end gap-1.5">
                    <button
                      :if={j.errors != []}
                      type="button"
                      phx-click="toggle_details"
                      phx-value-id={j.id}
                      class="text-ink-faint hover:text-ink text-[11px]"
                    >
                      {if MapSet.member?(@expanded, j.id), do: "Ocultar", else: "Detalhes"}
                    </button>
                    <button
                      :if={j.state in ["retryable", "discarded", "cancelled"]}
                      phx-click="retry"
                      phx-value-id={j.id}
                      class="rounded-md bg-primary/15 px-2.5 py-1 text-[11px] font-semibold text-primary hover:bg-primary/25"
                    >
                      Re-tentar
                    </button>
                    <button
                      :if={j.state in ["available", "scheduled", "executing", "retryable"]}
                      phx-click="cancel"
                      phx-value-id={j.id}
                      class="text-coral rounded-md bg-coral/10 px-2.5 py-1 text-[11px] hover:bg-coral/20"
                    >
                      Cancelar
                    </button>
                  </div>
                </td>
              </tr>
              <tr :if={MapSet.member?(@expanded, j.id)}>
                <td colspan="6" class="px-4 pb-3">
                  <div class="space-y-1 rounded-md bg-base px-3 py-2">
                    <p class="text-ink-muted break-all font-mono text-[11px]">{full_url(j)}</p>
                    <p
                      :for={line <- all_errors(j)}
                      class="text-coral break-all whitespace-pre-wrap font-mono text-[11px]"
                    >
                      {line}
                    </p>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
          <p :if={@jobs == []} class="text-ink-faint py-12 text-center text-body-sm">
            Nenhuma tarefa.
          </p>
        </div>
      </div>
    </.app_shell>
    """
  end

  # ── Worker name + label ────────────────────────────────────────────────────

  defp worker_name(worker), do: worker |> String.split(".") |> List.last()

  defp jobs_path(state, worker) do
    case Enum.reject([state: state, worker: worker], fn {_key, value} -> is_nil(value) end) do
      [] -> ~p"/jobs"
      params -> ~p"/jobs?#{params}"
    end
  end

  # Friendly PT-BR action labels per worker; falls back to the bare module segment
  # so a newly-added worker still renders something readable. The real module name
  # is always shown alongside as a small tag, so this is the "what it does", not a
  # replacement for the technical name.
  @worker_labels %{
    "AnalyzeWorker" => "Analisar áudio",
    "DownloadWorker" => "Baixar do YouTube",
    "ExpandWorker" => "Expandir playlist",
    "ImportWorker" => "Importar arquivos",
    "EnrichWorker" => "Enriquecer metadados",
    "ResolveSongWorker" => "Resolver no Soundcharts",
    "ReResolveWorker" => "Re-resolver match",
    "ReevaluateWorker" => "Re-avaliar com IA",
    "RecommendWorker" => "Sugerir repertório",
    "DedupWorker" => "Procurar duplicatas",
    "ScanWorker" => "Escanear biblioteca",
    "ReviewApplyWorker" => "Aplicar revisão no disco",
    "UndoBatchWorker" => "Desfazer lote"
  }

  defp worker_label(worker) do
    name = worker_name(worker)
    Map.get(@worker_labels, name, name)
  end

  # ── Human-readable summary (per worker, from args — never a dump of arg keys) ─

  defp job_summary(%Oban.Job{worker: worker, args: args}, titles),
    do: summarize(worker_name(worker), args, titles)

  defp summarize("DownloadWorker", args, _titles), do: args["title"] || args["url"] || "—"

  defp summarize("ExpandWorker", args, _titles),
    do: args["url"] || args["playlist_url"] || "playlist"

  defp summarize("AnalyzeWorker", args, titles), do: track_ref(args["track_id"], titles)
  defp summarize("ResolveSongWorker", args, titles), do: track_ref(args["track_id"], titles)
  defp summarize("EnrichWorker", args, titles), do: enrich_summary(args, titles)
  defp summarize("ReResolveWorker", args, _titles), do: "sugestão ##{args["suggestion_id"]}"
  defp summarize("ReevaluateWorker", args, _titles), do: reeval_summary(args)
  defp summarize("RecommendWorker", args, titles), do: recommend_summary(args, titles)
  defp summarize("ImportWorker", args, _titles), do: import_summary(args)
  defp summarize("DedupWorker", _args, _titles), do: "biblioteca inteira"
  defp summarize("ScanWorker", _args, _titles), do: "varredura da biblioteca"

  defp summarize("ReviewApplyWorker", %{"ids" => ids}, _titles),
    do: "#{length(ids)} sugestões selecionadas"

  defp summarize("UndoBatchWorker", %{"batch_id" => bid}, _titles),
    do: "lote ##{String.slice(to_string(bid), 0, 8)}"

  defp summarize(_worker, args, _titles), do: generic_summary(args)

  defp track_ref(nil, _titles), do: "—"

  defp track_ref(id, titles),
    do: Map.get(titles, id, "faixa ##{String.slice(to_string(id), 0, 8)}")

  defp enrich_summary(%{"scope" => "pending"}, _titles), do: "todas as pendentes · Soundcharts"

  defp enrich_summary(%{"scope" => "track", "id" => id}, titles),
    do: "#{track_ref(id, titles)} · Soundcharts"

  defp enrich_summary(_, _titles), do: "Soundcharts"

  defp reeval_summary(%{"scope" => "folder", "folder" => key}), do: "pasta: #{folder_label(key)}"
  defp reeval_summary(%{"scope" => "one", "id" => id}), do: "sugestão ##{id}"
  defp reeval_summary(%{"scope" => scope}), do: "escopo: #{reeval_scope(scope)}"
  defp reeval_summary(_), do: "—"

  defp reeval_scope("unevaluated"), do: "ainda não avaliadas"
  defp reeval_scope("pending"), do: "pendentes"
  defp reeval_scope("rejected"), do: "rejeitadas"
  defp reeval_scope(other), do: to_string(other)

  defp recommend_summary(%{"scope" => "folder", "folder" => key}, _titles),
    do: "pasta: #{folder_label(key)}"

  defp recommend_summary(%{"scope" => "track", "track_id" => id}, titles),
    do: track_ref(id, titles)

  defp recommend_summary(_, _titles), do: "repertório"

  defp import_summary(%{"items" => items}) when is_list(items), do: "#{length(items)} arquivo(s)"
  defp import_summary(_), do: "arquivos"

  defp generic_summary(args) do
    case args |> Map.drop(["batch_id"]) |> Map.values() |> Enum.filter(&is_binary/1) do
      [] -> "—"
      vals -> Enum.join(vals, " · ")
    end
  end

  # ── Timing ─────────────────────────────────────────────────────────────────

  defp job_time(%Oban.Job{} = j) do
    j.completed_at || j.cancelled_at || j.discarded_at || j.attempted_at || j.scheduled_at ||
      j.inserted_at
  end

  defp ago(nil), do: "—"

  defp ago(%NaiveDateTime{} = ndt), do: ago(DateTime.from_naive!(ndt, "Etc/UTC"))

  defp ago(%DateTime{} = dt) do
    case DateTime.diff(DateTime.utc_now(), dt, :second) do
      s when s < 5 -> "agora"
      s when s < 60 -> "há #{s}s"
      s when s < 3_600 -> "há #{div(s, 60)}min"
      s when s < 86_400 -> "há #{div(s, 3_600)}h"
      s -> "há #{div(s, 86_400)}d"
    end
  end

  # ── Errors / extra detail ──────────────────────────────────────────────────

  defp full_url(%Oban.Job{args: args}), do: args["url"] || args["title"] || ""

  defp all_errors(%Oban.Job{errors: errors}) do
    Enum.map(errors, fn e ->
      attempt = e["attempt"] || "?"
      msg = e["error"] || inspect(e)
      "tentativa #{attempt}: #{msg}"
    end)
  end

  defp last_error(%Oban.Job{errors: []}), do: nil

  defp last_error(%Oban.Job{errors: errors}) do
    case List.last(errors) do
      %{"error" => e} -> e |> to_string() |> String.slice(0, 160)
      _ -> nil
    end
  end

  # ── State labels / colors ──────────────────────────────────────────────────

  defp state_label("available"), do: "Na fila"
  defp state_label("scheduled"), do: "Agendada"
  defp state_label("executing"), do: "Executando"
  defp state_label("retryable"), do: "Retentável"
  defp state_label("completed"), do: "Concluída"
  defp state_label("discarded"), do: "Descartada"
  defp state_label("cancelled"), do: "Cancelada"
  defp state_label(s), do: s

  defp state_class("completed"), do: "bg-green/15 text-green"
  defp state_class("executing"), do: "bg-primary/15 text-primary"
  defp state_class(s) when s in ["discarded", "cancelled"], do: "bg-coral/15 text-coral"
  defp state_class("retryable"), do: "bg-amber/15 text-amber"
  defp state_class(_), do: "bg-white/10 text-ink-muted"

  defp chip_class(true), do: "border-primary/60 bg-primary/20 text-ink"
  defp chip_class(false), do: "border-white/8 bg-input text-ink-muted hover:border-white/20"
end
